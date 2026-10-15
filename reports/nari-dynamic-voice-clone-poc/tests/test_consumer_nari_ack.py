"""Real loopback transport + actual adapter/scheduler, model-free engine checkpoints."""
import asyncio
from concurrent.futures import ThreadPoolExecutor
from queue import Queue, Empty
import threading
import time
from types import SimpleNamespace
import uuid

import httpx
import pytest
from fastapi import FastAPI

from consumer_cancellation import ConsumerCancelled, bind_cancellation, retiring_pcm
from consumer_nari_ack import install_consumer_stop_ack, ENGINE_SHA256
from inference_scheduler import InferenceScheduler
from test_consumer_cancellation import Server, until, bound, TOKEN

class FakeStream:
    def __init__(self):self.queue=Queue()
    def read(self,timeout_s):
        try:return self.queue.get(timeout=timeout_s)
        except Empty:raise TimeoutError

class Engine:
    consumer_test_double=True
    consumer_test_command=staticmethod(lambda request_id,request,live,ids,wrapped,finished,reply:
        SimpleNamespace(request_id=request_id,request=request,reply=reply))
    def __init__(self):
        self._condition=threading.RLock();self._records={};self.submits=[];self.cancels=[]
        self.entered=threading.Event();self.submit_release=threading.Event();self.submit_release.set()
        self.reject_ready=False;self.reject_queue=False;self.reject_capacity=False;self.auto_complete=False
    def _require_ready(self):
        if self.reject_ready:raise RuntimeError('not ready before queue')
    def _put(self,command,timeout_s):
        if self.reject_queue:
            from queue import Full
            raise RuntimeError('queue full before enqueue') from Full()
        def execute():
            self.entered.set();self.submit_release.wait(3)
            if not command.reply.set_running_or_notify_cancel():return
            try:self._handle_submit(command)
            except BaseException as error:command.reply.set_exception(error)
        threading.Thread(target=execute,daemon=True).start()
    def _wait_future(self,future,timeout_s,request_id):
        try:return future.result(timeout_s)
        except TimeoutError:
            if not future.cancel():self.cancel(request_id,timeout_s=2)
            raise
    def _handle_submit(self,command):
        if self.reject_capacity:raise RuntimeError('active request capacity exceeded')
        record=SimpleNamespace(request_id=command.request_id,retired=False,stream=FakeStream())
        self._admit_record(record,request=command.request)
        with self._condition:self._records[record.request_id]=record;self.submits.append(record.request_id)
        record.stream.queue.put(b'\0\0'*240)
        command.reply.set_result(record.stream)
        if self.auto_complete:self.finish(record.request_id,True)
    def _admit_record(self,record,**kwargs):pass
    def cancel(self,request_id,timeout_s):
        self.cancels.append(request_id)  # Command accepted; engine has NOT retired.
    def _retire(self,record,completed):
        with self._condition:record.retired=True;self._records.pop(record.request_id,None)
    def finish(self,request_id,completed=False):
        record=self._records[request_id];record.stream.queue.put(None)
        self._retire(record,completed=completed)

def app_for(engine,capacity=4096):
    app=FastAPI();tracker=install_consumer_stop_ack(app,engine,parse_request=lambda body:body,
        token=TOKEN,verify_source=False,tracker_capacity=capacity)
    return app,tracker

def headers(tracker,rid):return {'X-Consumer-Nari-Token':TOKEN,'X-Consumer-Nari-Instance':tracker.instance_id,'X-Request-ID':rid,'X-Consumer-Nari-Lease':tracker.records.get(rid,{}).get('lease','')}

def prepare(server,tracker,rid):
    result=httpx.post(server.url+f'/v1/consumer/requests/{rid}/prepare',headers=headers(tracker,rid))
    assert result.status_code==200
    return result.json()['lease']
BODY={'input':'consumer text remains the original contract','response_format':'pcm','stream':True}

def test_cancelled_http_holds_shared_scheduler_until_exact_engine_ack():
    engine=Engine();app,tracker=app_for(engine);cancel=threading.Event();scheduler=InferenceScheduler();second_started=threading.Event()
    with Server(app) as server,ThreadPoolExecutor(2) as pool:
        first=pool.submit(bound,cancel,lambda:scheduler.submit(lambda:retiring_pcm(server.url,json=BODY,
            timeout=2,deadline_at=time.monotonic()+2,token=TOKEN),kind='consumer',timeout_s=2))
        until(lambda:len(engine.submits)==1);rid=engine.submits[0];cancel.set()
        with pytest.raises(ConsumerCancelled):first.result(1)
        until(lambda:rid in engine.cancels)
        assert not tracker.state(rid)['engine_stopped']
        second=pool.submit(scheduler.submit,lambda:second_started.set(),kind='next',timeout_s=2)
        time.sleep(.15)
        assert scheduler.snapshot()['busy'] and not second_started.is_set()
        engine.finish(rid)
        second.result(2);assert second_started.is_set()
        until(lambda:not scheduler.snapshot()['busy'])
    scheduler.close()

def test_normal_pcm_completion_still_waits_for_engine_retirement():
    engine=Engine();app,tracker=app_for(engine)
    with Server(app) as server,ThreadPoolExecutor(1) as pool:
        result=pool.submit(retiring_pcm,server.url,json=BODY,timeout=2,deadline_at=time.monotonic()+2,token=TOKEN)
        until(lambda:len(engine.submits)==1);rid=engine.submits[0]
        engine._records[rid].stream.queue.put(None)
        time.sleep(.15);assert not result.done() and engine.cancels==[]
        engine.finish(rid,True)
        status,pcm=result.result(2);assert status==200 and len(pcm)==480

def test_cancel_before_submit_is_exact_tombstone_and_duplicate_cannot_start():
    engine=Engine();app,tracker=app_for(engine);rid='ctts_'+uuid.uuid4().hex
    with Server(app) as server:
        prepare(server,tracker,rid)
        cancel=httpx.post(server.url+f'/v1/consumer/requests/{rid}/cancel',headers=headers(tracker,rid))
        assert cancel.json()['engine_stopped'] and cancel.json()['proof']=='engine-not-submitted-v1'
        response=httpx.post(server.url+'/v1/consumer/audio/speech',headers=headers(tracker,rid),json=BODY)
        assert response.status_code==409 and engine.submits==[]

def test_cancel_during_submit_does_not_claim_stopped_or_lose_late_submission():
    engine=Engine();engine.submit_release.clear();app,tracker=app_for(engine);rid='ctts_'+uuid.uuid4().hex
    with Server(app) as server,ThreadPoolExecutor(1) as pool:
        prepare(server,tracker,rid)
        result=pool.submit(httpx.post,server.url+'/v1/consumer/audio/speech',headers=headers(tracker,rid),json=BODY,timeout=3)
        assert engine.entered.wait(1)
        response=httpx.post(server.url+f'/v1/consumer/requests/{rid}/cancel',headers=headers(tracker,rid))
        assert response.json()['engine_stopped'] is False
        engine.submit_release.set();until(lambda:len(engine.submits)==1 and engine.cancels.count(engine.submits[0])>=2)
        assert tracker.state(rid)['engine_stopped'] is False
        engine.finish(engine.submits[0]);result.result(2)
        assert tracker.state(rid)['engine_stopped'] is True

def test_wrong_auth_instance_and_unknown_are_never_stop_evidence():
    engine=Engine();app,tracker=app_for(engine);rid='ctts_'+uuid.uuid4().hex
    with Server(app) as server:
        path=server.url+f'/v1/consumer/requests/{rid}/state'
        assert httpx.get(path).status_code==401
        wrong={**headers(tracker,rid),'X-Consumer-Nari-Instance':'0'*32}
        assert httpx.get(path,headers=wrong).status_code==409
        assert httpx.get(path,headers=headers(tracker,rid)).json()['engine_stopped'] is False

def test_body_failure_before_submit_has_exact_non_submission_proof():
    engine=Engine();app,tracker=app_for(engine);rid='ctts_'+uuid.uuid4().hex
    with Server(app) as server:
        prepare(server,tracker,rid)
        response=httpx.post(server.url+'/v1/consumer/audio/speech',headers=headers(tracker,rid),json={})
        assert response.status_code==422 and engine.submits==[]
        assert tracker.state(rid)['proof']=='engine-not-submitted-v1'

def test_real_engine_source_is_pinned_and_test_bypass_is_explicit():
    with pytest.raises(ValueError):install_consumer_stop_ack(FastAPI(),object(),parse_request=lambda x:x,token=TOKEN,verify_source=False)
    from pathlib import Path
    import hashlib
    assert hashlib.sha256((Path(__file__).parent/'fixtures/consumer_nari_engine.py').read_bytes()).hexdigest()==ENGINE_SHA256

def test_lost_or_wrong_ack_never_releases_slot_and_eventual_exact_ack_recovers():
    engine=Engine();app,tracker=app_for(engine);scheduler=InferenceScheduler();cancel=threading.Event()
    allow_exact=threading.Event();original_state=tracker.state
    def corrupt_state(request_id):
        value=original_state(request_id)
        if value['engine_stopped'] and not allow_exact.is_set():
            return {**value,'request_id':'ctts_'+'f'*32}
        return value
    tracker.state=corrupt_state
    with Server(app) as server,ThreadPoolExecutor(1) as pool:
        first=pool.submit(bound,cancel,lambda:scheduler.submit(lambda:retiring_pcm(server.url,json=BODY,
            timeout=2,deadline_at=time.monotonic()+2,token=TOKEN),kind='consumer',timeout_s=2))
        until(lambda:len(engine.submits)==1);rid=engine.submits[0];cancel.set()
        with pytest.raises(ConsumerCancelled):first.result(1)
        until(lambda:rid in engine.cancels);engine.finish(rid)
        time.sleep(.15);assert scheduler.snapshot()['busy']
        allow_exact.set();until(lambda:not scheduler.snapshot()['busy'])
    scheduler.close()

def test_body_deadline_closes_pcm_but_does_not_release_callback_before_ack():
    engine=Engine();app,tracker=app_for(engine)
    with Server(app) as server,ThreadPoolExecutor(1) as pool:
        future=pool.submit(retiring_pcm,server.url,json=BODY,timeout=2,deadline_at=time.monotonic()+.15,token=TOKEN)
        until(lambda:len(engine.submits)==1);rid=engine.submits[0]
        until(lambda:rid in engine.cancels);assert not future.done()
        engine.finish(rid)
        with pytest.raises(TimeoutError):future.result(2)

def test_original_engine_retirement_removes_pipeline_before_publishing_ack():
    # Execute the exact deployed _retire method (GPU methods stubbed), then the
    # adapter's real observer. A fake "cancel accepted" is insufficient.
    import ast
    from pathlib import Path
    from types import MethodType
    tree=ast.parse((Path(__file__).parent/'fixtures/consumer_nari_engine.py').read_text())
    cls=next(x for x in tree.body if isinstance(x,ast.ClassDef) and x.name=='Engine')
    method=next(x for x in cls.body if isinstance(x,ast.FunctionDef) and x.name=='_retire')
    module=ast.Module(body=[ast.ImportFrom(module='__future__',names=[ast.alias(name='annotations')],level=0),method],type_ignores=[])
    scope={};exec(compile(ast.fix_missing_locations(module),'actual-nari-retire','exec'),scope)
    engine=Engine();removed=[];engine._condition=threading.Condition()
    engine._remove_request=lambda request_id:removed.append(request_id)
    engine._set_metrics=lambda **changes:None
    engine._retire=MethodType(scope['_retire'],engine)
    app,tracker=app_for(engine);rid='ctts_'+uuid.uuid4().hex;lease=tracker.begin(rid)['lease'];tracker.claim(rid,lease);tracker.before_submit(rid,lease)
    engine_id=rid+'__'+lease
    record=SimpleNamespace(request_id=engine_id,retired=False,admitted=True)
    engine._records[engine_id]=record
    assert not tracker.state(rid)['engine_stopped']
    engine._retire(record,completed=False)
    assert removed==[engine_id] and engine_id not in engine._records and tracker.state(rid)['engine_stopped']

def test_original_validation_status_survives_exact_ack_cleanup():
    engine=Engine();app,tracker=app_for(engine)
    with Server(app) as server:
        status,data=retiring_pcm(server.url,json={},timeout=2,deadline_at=time.monotonic()+2,token=TOKEN)
        assert status==422 and data==b'' and engine.submits==[]

def test_capacity_one_continuous_completed_attempts_consume_ack_and_reuse_capacity():
    engine=Engine();engine.auto_complete=True;app,tracker=app_for(engine,capacity=1)
    with Server(app) as server:
        for _ in range(3):
            status,pcm=retiring_pcm(server.url,json=BODY,timeout=2,deadline_at=time.monotonic()+2,token=TOKEN)
            assert status==200 and len(pcm)==480
            assert tracker.records=={}, 'only explicitly acknowledged terminal records are reclaimed'
    assert len(engine.submits)==3 and len(set(engine.submits))==3

def test_full_capacity_exact_no_lease_proof_never_starts_gpu_or_holds_scheduler():
    engine=Engine();app,tracker=app_for(engine,capacity=1);scheduler=InferenceScheduler()
    first='ctts_'+uuid.uuid4().hex;second='ctts_'+uuid.uuid4().hex
    with Server(app) as server:
        prepare(server,tracker,first)
        rejected=httpx.post(server.url+f'/v1/consumer/requests/{second}/prepare',headers=headers(tracker,second))
        proof=rejected.json()['detail']
        assert rejected.status_code==429 and proof['request_id']==second
        assert proof['instance_id']==tracker.instance_id and proof['proof']=='admission-lease-not-issued-v1'
        result=scheduler.submit(lambda:retiring_pcm(server.url,json=BODY,timeout=2,
            deadline_at=time.monotonic()+2,token=TOKEN),kind='consumer',timeout_s=2)
        assert result.value==(429,b'') and not scheduler.snapshot()['busy'] and engine.submits==[]
        httpx.post(server.url+f'/v1/consumer/requests/{first}/cancel',headers=headers(tracker,first))
        assert tracker.state(first)['engine_stopped']
        ack=httpx.post(server.url+f'/v1/consumer/requests/{first}/ack',headers=headers(tracker,first))
        assert ack.status_code==200
        engine.auto_complete=True
        result=scheduler.submit(lambda:retiring_pcm(server.url,json=BODY,timeout=2,
            deadline_at=time.monotonic()+2,token=TOKEN),kind='consumer',timeout_s=2)
        assert result.value[0]==200 and len(engine.submits)==1
    scheduler.close()

def test_unconsumed_terminal_is_not_evicted_and_old_lease_cannot_resubmit_after_ack():
    engine=Engine();app,tracker=app_for(engine,capacity=1);rid='ctts_'+uuid.uuid4().hex
    with Server(app) as server:
        prepare(server,tracker,rid);old_headers=headers(tracker,rid)
        httpx.post(server.url+f'/v1/consumer/requests/{rid}/cancel',headers=old_headers)
        tracker.records[rid]['expires']=time.monotonic()-1000000
        other='ctts_'+uuid.uuid4().hex
        assert httpx.post(server.url+f'/v1/consumer/requests/{other}/prepare',headers=headers(tracker,other)).status_code==429
        assert tracker.state(rid)['engine_stopped'], 'unconsumed terminal cannot be lost to TTL'
        assert httpx.post(server.url+f'/v1/consumer/requests/{rid}/ack',headers=old_headers).status_code==200
        assert httpx.post(server.url+'/v1/consumer/audio/speech',headers=old_headers,json=BODY).status_code==409
        prepare(server,tracker,rid)
        assert headers(tracker,rid)['X-Consumer-Nari-Lease']!=old_headers['X-Consumer-Nari-Lease']
        assert httpx.post(server.url+'/v1/consumer/audio/speech',headers=old_headers,json=BODY).status_code==409
        assert engine.submits==[]

@pytest.mark.parametrize('rejection',['reject_ready','reject_queue','reject_capacity'])
def test_pre_engine_rejections_publish_exact_no_submission_and_keep_queue_live(rejection):
    engine=Engine();setattr(engine,rejection,True);app,tracker=app_for(engine,capacity=1);scheduler=InferenceScheduler()
    with Server(app) as server:
        result=scheduler.submit(lambda:retiring_pcm(server.url,json=BODY,timeout=2,
            deadline_at=time.monotonic()+2,token=TOKEN),kind='consumer',timeout_s=2)
        assert result.value==(503,b'')
        assert engine.submits==[] and not scheduler.snapshot()['busy'] and not tracker.records
        setattr(engine,rejection,False);engine.auto_complete=True
        result=scheduler.submit(lambda:retiring_pcm(server.url,json=BODY,timeout=2,
            deadline_at=time.monotonic()+2,token=TOKEN),kind='consumer',timeout_s=2)
        assert result.value[0]==200 and len(engine.submits)==1
    scheduler.close()

def test_expired_unused_reservation_is_reclaimable_but_old_audio_lease_is_invalid():
    engine=Engine();app,tracker=app_for(engine,capacity=1);rid='ctts_'+uuid.uuid4().hex
    with Server(app) as server:
        prepare(server,tracker,rid);old_headers=headers(tracker,rid)
        tracker.records[rid]['expires']=time.monotonic()-1
        other='ctts_'+uuid.uuid4().hex;prepare(server,tracker,other)
        assert rid not in tracker.records
        assert httpx.post(server.url+'/v1/consumer/audio/speech',headers=old_headers,json=BODY).status_code==409
        assert engine.submits==[]

def test_exact_deployed_capacity_validation_proves_no_admission():
    # Use the deployed Engine._handle_submit, rather than a mirrored rejection.
    import ast
    from pathlib import Path
    from types import MethodType
    tree=ast.parse((Path(__file__).parent/'fixtures/consumer_nari_engine.py').read_text())
    cls=next(x for x in tree.body if isinstance(x,ast.ClassDef) and x.name=='Engine')
    method=next(x for x in cls.body if isinstance(x,ast.FunctionDef) and x.name=='_handle_submit')
    scope={'SynthesisRequest':dict,'ServiceCapacityExceeded':RuntimeError}
    module=ast.Module(body=[ast.ImportFrom(module='__future__',names=[ast.alias(name='annotations')],level=0),method],type_ignores=[])
    exec(compile(ast.fix_missing_locations(module),'actual-nari-submit-validation','exec'),scope)
    engine=Engine();engine._handle_submit=MethodType(scope['_handle_submit'],engine)
    engine._records['existing']=object();engine.config=SimpleNamespace(max_active_requests=1)
    app,tracker=app_for(engine,capacity=1)
    with Server(app) as server:
        status,data=retiring_pcm(server.url,json=BODY,timeout=2,deadline_at=time.monotonic()+2,token=TOKEN)
        assert status==503 and data==b'' and engine.submits==[] and tracker.records=={}

def test_exact_deployed_put_and_future_cancel_prove_command_never_started():
    import ast
    import queue
    from pathlib import Path
    from types import MethodType
    from concurrent.futures import Future, TimeoutError as FutureTimeoutError
    from consumer_nari_ack import observed_submit
    tree=ast.parse((Path(__file__).parent/'fixtures/consumer_nari_engine.py').read_text())
    cls=next(x for x in tree.body if isinstance(x,ast.ClassDef) and x.name=='Engine')
    methods=[x for x in cls.body if isinstance(x,ast.FunctionDef) and x.name in {'_put','_wait_future'}]
    scope={'queue':queue,'ServiceCapacityExceeded':RuntimeError,'FutureTimeoutError':FutureTimeoutError,'Future':Future}
    module=ast.Module(body=[ast.ImportFrom(module='__future__',names=[ast.alias(name='annotations')],level=0)]+methods,type_ignores=[])
    exec(compile(ast.fix_missing_locations(module),'actual-nari-queue-command','exec'),scope)
    for full in [True,False]:
        engine=Engine();app,tracker=app_for(engine)
        engine._commands=queue.Queue(maxsize=1)
        engine._put=MethodType(scope['_put'],engine);engine._wait_future=MethodType(scope['_wait_future'],engine)
        if full:engine._commands.put(object())
        rid='ctts_'+uuid.uuid4().hex;lease=tracker.begin(rid)['lease'];tracker.claim(rid,lease);tracker.before_submit(rid,lease)
        with pytest.raises((RuntimeError,TimeoutError)):
            observed_submit(engine,tracker,rid+'__'+lease,BODY,engine.consumer_test_command,timeout_s=.01)
        proof=tracker.state(rid)
        assert proof['engine_stopped'] and proof['proof']=='engine-not-submitted-v1'
        assert engine.submits==[]

def test_ack_cleanup_failure_retains_receipt_but_never_holds_a_retired_gpu_slot():
    engine=Engine();engine.auto_complete=True;app,tracker=app_for(engine,capacity=1);scheduler=InferenceScheduler()
    def unavailable(*_):
        from fastapi import HTTPException
        raise HTTPException(503,'fixture ACK persistence unavailable')
    tracker.acknowledge=unavailable
    with Server(app) as server:
        result=scheduler.submit(lambda:retiring_pcm(server.url,json=BODY,timeout=2,
            deadline_at=time.monotonic()+2,token=TOKEN),kind='consumer',timeout_s=2)
        assert result.value[0]==200 and not scheduler.snapshot()['busy']
        assert len(tracker.records)==1 and all(r['engine_stopped'] for r in tracker.records.values())
        result=scheduler.submit(lambda:retiring_pcm(server.url,json=BODY,timeout=2,
            deadline_at=time.monotonic()+2,token=TOKEN),kind='consumer',timeout_s=2)
        assert result.value==(429,b'') and not scheduler.snapshot()['busy'] and len(engine.submits)==1
    scheduler.close()

def test_late_claimed_body_and_old_engine_ack_cannot_mutate_reused_id_new_lease():
    import json
    import socket
    engine=Engine();app,tracker=app_for(engine,capacity=1);rid='ctts_'+uuid.uuid4().hex
    with Server(app) as server:
        old_lease=prepare(server,tracker,rid);old_headers=headers(tracker,rid)
        body=json.dumps(BODY).encode();host,port=server.url.removeprefix('http://').split(':')
        sock=socket.create_connection((host,int(port)),timeout=2)
        prefix=(f'POST /v1/consumer/audio/speech HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\n'+''.join(f'{k}: {v}\r\n' for k,v in old_headers.items())+f'Content-Length: {len(body)}\r\n\r\n').encode()
        sock.sendall(prefix+body[:1]);until(lambda:tracker.records[rid]['phase']=='preparing')
        assert httpx.post(server.url+f'/v1/consumer/requests/{rid}/cancel',headers=old_headers).json()['engine_stopped']
        assert httpx.post(server.url+f'/v1/consumer/requests/{rid}/ack',headers=old_headers).status_code==200
        new_lease=prepare(server,tracker,rid);assert new_lease!=old_lease
        sock.sendall(body[1:]);response=sock.recv(4096);sock.close()
        assert b'499' in response and engine.submits==[]
        tracker.retired(rid+'__'+old_lease,False)
        tracker.not_submitted(rid+'__'+old_lease,command_proof=True)
        assert tracker.records[rid]['phase']=='reserved' and not tracker.state(rid)['engine_stopped']
        assert httpx.post(server.url+f'/v1/consumer/requests/{rid}/cancel',headers=old_headers).status_code==409
        assert not tracker.records[rid]['cancel_requested']
