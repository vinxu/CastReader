import ast
import asyncio
from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
import io
import pathlib
import socket
import sys
import threading
import time
from types import SimpleNamespace
import wave

import pytest
import httpx
import uvicorn
from fastapi import FastAPI, Header, HTTPException, Request, Depends
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel

ROOT=pathlib.Path(__file__).parents[1]
sys.path.insert(0,str(ROOT/'worker'))
sys.path.insert(0,str(ROOT/'consumer-cancellation/alignment'))
from consumer_cancellation import (ConsumerCancelled, SharedCancellation, bind_cancellation,
    check_cancelled, current_cancellation, run_on_disconnect, cancellable_post, cancellable_pcm, retiring_pcm)
from request_coalescer import RequestCoalescer, IdempotencyConflict
from inference_scheduler import (InferenceScheduler,ScheduledResult,SchedulerOverloaded,SchedulerDeadlineExceeded,
    PRIORITY_INTERACTIVE,PRIORITY_PREFETCH,PRIORITY_BACKGROUND)
from alignment_gateway import AlignmentGateway, WireResult, build_app
from caption_pipeline import CaptionPipeline, PCM, EncodedAudio
import numpy as np

TOKEN='fixture-token-never-a-production-secret'


def until(predicate, timeout=3):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        if predicate():return
        time.sleep(.005)
    raise AssertionError('fixture did not reach expected state')


def bound(cancel, operation):
    with bind_cancellation(cancel):return operation()


def test_shared_consumers_one_disconnect_does_not_cancel_other():
    coalescer=RequestCoalescer();first=threading.Event();second=threading.Event()
    entered=threading.Event();release=threading.Event();count=[]
    def run():
        entered.set();count.append(1);release.wait(2);check_cancelled();return 'audio'
    with ThreadPoolExecutor(2) as pool:
        a=pool.submit(bound,first,lambda:coalescer.execute('same','fingerprint',run,wait_timeout_s=2))
        assert entered.wait(1)
        b=pool.submit(bound,second,lambda:coalescer.execute('same','fingerprint',run,wait_timeout_s=2))
        until(lambda:len(coalescer._inflight['same'].cancellation._consumers)==2)
        first.set();release.set()
        with pytest.raises(ConsumerCancelled):a.result(1)
        assert b.result(1).value=='audio'
    assert len(count)==1
    assert coalescer.execute('same','fingerprint',lambda:pytest.fail('duplicated'),wait_timeout_s=1).value=='audio'


def test_all_consumers_cancel_then_same_billing_id_can_retry_after_terminal():
    coalescer=RequestCoalescer();cancel=threading.Event();entered=threading.Event()
    def run():
        entered.set()
        while not current_cancellation().is_set():time.sleep(.002)
        check_cancelled()
    with ThreadPoolExecutor(1) as pool:
        future=pool.submit(bound,cancel,lambda:coalescer.execute('same','fingerprint',run,wait_timeout_s=2))
        assert entered.wait(1);cancel.set()
        with pytest.raises(ConsumerCancelled):future.result(1)
    assert not coalescer._inflight and not coalescer._cache
    assert coalescer.execute('same','fingerprint',lambda:'recovered',wait_timeout_s=1).value=='recovered'


def test_cancel_latches_and_conflicting_billing_id_remains_rejected():
    group=SharedCancellation();cancel=threading.Event();group.add(cancel);cancel.set()
    assert group.is_set()
    with pytest.raises(ConsumerCancelled):group.add(threading.Event())
    coalescer=RequestCoalescer();coalescer.execute('id','one',lambda:'audio',wait_timeout_s=1)
    with pytest.raises(IdempotencyConflict):coalescer.execute('id','two',lambda:'bad',wait_timeout_s=1)


def test_queued_cancel_never_executes_and_active_cancel_keeps_slot_until_checkpoint():
    scheduler=InferenceScheduler();started=threading.Event();release=threading.Event();cancel=threading.Event();ran=[]
    with ThreadPoolExecutor(3) as pool:
        active=pool.submit(scheduler.submit,lambda:(started.set(),release.wait(2)),kind='block',timeout_s=3)
        assert started.wait(1)
        pending=pool.submit(bound,cancel,lambda:scheduler.submit(lambda:ran.append(1),kind='speech',timeout_s=2))
        until(lambda:scheduler.snapshot()['queue_depth']==1);cancel.set()
        with pytest.raises(ConsumerCancelled):pending.result(1)
        assert scheduler.snapshot()['busy']
        assert scheduler.snapshot()['queue_depth']==0, 'cancelled admission is reclaimed before active job finishes'
        release.set();active.result(1)
    scheduler.close();assert ran==[]


class Server:
    def __init__(self,app):
        sock=socket.socket();sock.bind(('127.0.0.1',0));self.url=f'http://127.0.0.1:{sock.getsockname()[1]}'
        self.server=uvicorn.Server(uvicorn.Config(app,log_level='error',lifespan='off',access_log=False))
        self.thread=threading.Thread(target=lambda:self.server.run(sockets=[sock]),daemon=True)
    def __enter__(self):
        self.thread.start();until(lambda:self.server.started);return self
    def __exit__(self,*_):
        self.server.should_exit=True;self.thread.join(4);assert not self.thread.is_alive()


class SpeechRequest(BaseModel):
    text:str
    voice_id:str
    language_id:str='en'


def build_worker(scheduler,nari_url,token_path):
    # Execute changed production functions, not a duplicate fixture handler.
    tree=ast.parse((ROOT/'worker/clone_worker.py').read_text())
    names={'schedule','timing_headers','request_priority','nari_streamed_wav','schedule_validated_voice','_speech_sync','speech'}
    nodes=[node for node in tree.body if isinstance(node,(ast.FunctionDef,ast.AsyncFunctionDef)) and node.name in names]
    app=FastAPI()
    def require_token(x_clone_token:str|None=Header(default=None)):
        if x_clone_token!=TOKEN:raise HTTPException(401)
    scope=dict(app=app,Depends=Depends,require_token=require_token,Request=Request,SpeechRequest=SpeechRequest,
        Response=Response,Header=Header,HTTPException=HTTPException,ScheduledResult=ScheduledResult,
        SCHEDULER=scheduler,SchedulerOverloaded=SchedulerOverloaded,SchedulerDeadlineExceeded=SchedulerDeadlineExceeded,
        PRIORITY_INTERACTIVE=PRIORITY_INTERACTIVE,PRIORITY_PREFETCH=PRIORITY_PREFETCH,PRIORITY_BACKGROUND=PRIORITY_BACKGROUND,
        NARI_URL=nari_url,NARI_REQUEST_TIMEOUT_SECONDS=3,SYNTHESIS_TIMEOUT_SECONDS=3,SAMPLE_RATE=24000,
        time=time,io=io,wave=wave,structured_log=lambda *a,**k:None,
        check_cancelled=check_cancelled,run_on_disconnect=run_on_disconnect,cancellable_pcm=cancellable_pcm,
        retiring_pcm=retiring_pcm,os=SimpleNamespace(environ={"CONSUMER_NARI_TOKEN_FILE":str(token_path)}),Path=pathlib.Path,
        SemanticASRUnavailable=type('SemanticASRUnavailable',(Exception,),{}),
        SemanticAudioMismatch=type('SemanticAudioMismatch',(Exception,),{}))
    future=ast.ImportFrom(module='__future__',names=[ast.alias(name='annotations')],level=0)
    exec(compile(ast.fix_missing_locations(ast.Module(body=[future]+nodes,type_ignores=[])),str(ROOT/'worker/clone_worker.py'),'exec'),scope)
    scope['request_voice_candidate']=lambda request,deadline_at:SimpleNamespace(wav=scope['nari_streamed_wav']({'input':request.text},deadline_at=deadline_at)[1],mode='x-vector')
    scope['validate_voice_candidate']=lambda request,value:SimpleNamespace(wav=value.wav,asr=None)
    return app


class Pipeline:
    def __init__(self):self.calls=0;self.cancellations=[]
    def caption(self,pcm,**options):
        check_cancelled(options['cancel']);self.calls+=1;self.cancellations.append(options['cancel'])
        return SimpleNamespace(response={'audio':'V0FW','audio_format':'audio/mpeg','voice_code':'vc_fixture','timestamps':[]},
            reason='fixture',duration=.1,timings={})
    def close(self):pass


@contextmanager
def chain(tmp_path, *, hold_nari=False):
    nari=FastAPI();started=threading.Event();closed=threading.Event();release=threading.Event();requests=[]
    if not hold_nari:release.set()
    from consumer_nari_ack import PROTOCOL, ENGINE_SHA256
    states={}; instance='a'*32
    @nari.get('/v1/consumer/capabilities')
    async def capabilities():return dict(protocol=PROTOCOL,engine_source_sha256=ENGINE_SHA256,instance_id=instance)
    @nari.post('/v1/consumer/requests/{request_id}/prepare')
    async def prepare(request_id:str):return dict(protocol=PROTOCOL,request_id=request_id,instance_id=instance,lease='b'*32)
    @nari.post('/v1/consumer/requests/{request_id}/ack')
    async def acknowledge(request_id:str):return {'acknowledged':True}
    def state(request_id):return dict(protocol=PROTOCOL,engine_source_sha256=ENGINE_SHA256,instance_id=instance,
        request_id=request_id,lease='b'*32,state='done' if states.get(request_id) else 'unknown',engine_stopped=bool(states.get(request_id)),proof='engine-retired-v1')
    @nari.get('/v1/consumer/requests/{request_id}/state')
    async def get_state(request_id:str):return state(request_id)
    @nari.post('/v1/consumer/requests/{request_id}/cancel')
    async def cancel(request_id:str):return state(request_id)
    @nari.post('/v1/consumer/audio/speech')
    async def audio(request:Request):
        body=await request.json();requests.append(body);started.set();request_id=request.headers["x-request-id"]
        async def pcm():
            try:
                yield b'\0\0'*240
                while not release.is_set():await asyncio.sleep(.005)
                yield b'\0\0'*2160
            finally:states[request_id]=True;closed.set()
        return StreamingResponse(pcm(),media_type='audio/pcm')
    scheduler=InferenceScheduler();pipeline=Pipeline();(tmp_path/'vc_fixture').mkdir();(tmp_path/'vc_fixture/prompt.pt').write_bytes(b'fixture')
    token_path=tmp_path/"test-token";token_path.write_text(TOKEN)
    with Server(nari) as nari_server:
        with Server(build_worker(scheduler,nari_server.url,token_path)) as worker:
            def synthesize(request,request_id,priority):
                response=cancellable_post(worker.url+'/v1/speech',headers={'X-Clone-Token':TOKEN,'X-Request-ID':request_id},
                    json={'text':request.input,'voice_id':request.voice,'language_id':request.language},timeout=3)
                return (response.content,dict(response.headers)) if response.status_code==200 else WireResult(response.status_code,{'error':'fixture-upstream'}, {})
            gateway=AlignmentGateway(pipeline=pipeline,voices=tmp_path,synthesize=synthesize)
            with Server(build_app(gateway,TOKEN)) as alignment:
                try:yield SimpleNamespace(url=alignment.url,gateway=gateway,scheduler=scheduler,pipeline=pipeline,started=started,closed=closed,release=release,requests=requests,nari=nari_server)
                finally:release.set();scheduler.close()


BODY={'input':'Only fixture speech.','voice':'vc_fixture','language':'en','speed':1}

def start_request(c):
    # A real TCP socket, not ASGITransport: shutdown emits http.disconnect.
    import json
    host,port=c.url.removeprefix('http://').split(':');sock=socket.create_connection((host,int(port)),timeout=2)
    data=json.dumps(BODY).encode();sock.sendall((f'POST /v1/captioned-speech HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nX-Clone-Token: {TOKEN}\r\nX-Request-ID: fixture-http\r\nContent-Length: {len(data)}\r\n\r\n').encode()+data)
    return sock


def test_real_http_disconnect_while_queued_prevents_nari_and_alignment(tmp_path):
    with chain(tmp_path) as c:
        entered=threading.Event();release=threading.Event()
        with ThreadPoolExecutor(1) as pool:
            blocker=pool.submit(c.scheduler.submit,lambda:(entered.set(),release.wait(2)),kind='blocker',timeout_s=3)
            assert entered.wait(1);sock=start_request(c);until(lambda:c.scheduler.snapshot()['queue_depth']==1)
            sock.shutdown(socket.SHUT_RDWR);sock.close()
            until(lambda:all(job.cancelled or job.cancellation.is_set() for q in c.scheduler._queues.values() for job in q))
            release.set();blocker.result(1);until(lambda:c.scheduler.snapshot()['queue_depth']==0)
        assert c.requests==[] and c.pipeline.calls==0


def test_real_http_disconnect_during_nari_closes_socket_and_suppresses_alignment(tmp_path):
    with chain(tmp_path,hold_nari=True) as c:
        sock=start_request(c);assert c.started.wait(2);sock.shutdown(socket.SHUT_RDWR);sock.close()
        assert c.closed.wait(2),'Nari stream must close without waiting for another PCM chunk'
        until(lambda:not c.scheduler.snapshot()['busy'])
        assert len(c.requests)==1 and c.pipeline.calls==0


def test_real_http_success_contract_idempotency_and_second_consumer_survives(tmp_path):
    with chain(tmp_path,hold_nari=True) as c:
        sock=start_request(c);assert c.started.wait(2)
        with ThreadPoolExecutor(1) as pool:
            second=pool.submit(httpx.post,c.url+'/v1/captioned-speech',json=BODY,headers={'X-Clone-Token':TOKEN,'X-Request-ID':'fixture-http'},timeout=3)
            until(lambda:len(c.gateway.requests._inflight['fixture-http'].cancellation._consumers)==2)
            sock.shutdown(socket.SHUT_RDWR);sock.close();time.sleep(.06)
            assert c.scheduler.snapshot()['busy'],'other consumer still owns current synthesis'
            c.release.set();response=second.result(2)
        assert response.status_code==200
        assert set(response.json())=={'audio','audio_format','voice_code','timestamps'}
        replay=httpx.post(c.url+'/v1/captioned-speech',json=BODY,headers={'X-Clone-Token':TOKEN,'X-Request-ID':'fixture-http'},timeout=2)
        assert replay.status_code==200 and len(c.requests)==1 and c.pipeline.calls==1


def test_silent_nari_stream_retains_total_deadline():
    app=FastAPI();closed=threading.Event()
    @app.post('/pcm')
    async def pcm():
        async def stream():
            try:
                yield b'\0\0'
                await asyncio.sleep(5)
            finally:closed.set()
        return StreamingResponse(stream())
    with Server(app) as server:
        before=time.monotonic()
        with pytest.raises(TimeoutError):cancellable_pcm(server.url+'/pcm',json={},timeout=3,deadline_at=time.monotonic()+.1)
        assert time.monotonic()-before<1 and closed.wait(1)


def test_running_alignment_keeps_slot_until_cuda_callback_returns():
    entered=threading.Event();release=threading.Event();cancel=threading.Event()
    def aligner(*args):entered.set();release.wait(2);return []
    pipeline=CaptionPipeline(aligner,max_inflight=1,alignment_budget_s=2,
        encoder=lambda pcm:EncodedAudio(b'fixture',pcm.duration))
    pcm=PCM(np.zeros(2400,dtype=np.float32),24000)
    with ThreadPoolExecutor(1) as pool:
        work=pool.submit(pipeline.caption,pcm,text='Fixture',language='en',voice_code='vc_fixture',cancel=cancel)
        assert entered.wait(1);cancel.set()
        from caption_pipeline import PipelineCancelled
        with pytest.raises(PipelineCancelled):work.result(1)
        assert not pipeline.slots.acquire(blocking=False),'running CUDA forward still owns admission'
        release.set();until(lambda:pipeline.slots.acquire(blocking=False));pipeline.slots.release()
    pipeline.close()


def test_compatibility_caption_handler_preserves_headers_and_four_field_body():
    tree=ast.parse((ROOT/'worker/clone_worker.py').read_text())
    function=next(node for node in tree.body if isinstance(node,ast.AsyncFunctionDef) and node.name=='captioned_speech')
    class CaptionedSpeechRequest(BaseModel):
        input:str
    app=FastAPI()
    def require_token():pass
    body={'audio':'fixture','audio_format':'audio/mpeg','timestamps':[],'voice_code':'vc_fixture'}
    def sync(request,response,*_):
        response.headers['X-TTS-Request-ID']='fixture-id'
        return body
    scope=dict(app=app,Depends=Depends,require_token=require_token,Request=Request,CaptionedSpeechRequest=CaptionedSpeechRequest,
        Header=Header,Response=Response,run_on_disconnect=run_on_disconnect,_captioned_speech_sync=sync)
    exec(compile(ast.fix_missing_locations(ast.Module(body=[function],type_ignores=[])),'candidate-caption-wrapper','exec'),scope)
    with Server(app) as server:
        response=httpx.post(server.url+'/v1/captioned-speech',json={'input':'fixture'})
        assert response.status_code==200 and response.json()==body
        assert response.headers['x-tts-request-id']=='fixture-id'
        assert int(response.headers['content-length'])==len(response.content)>0


def test_http_cancel_then_new_same_billing_id_resumes_after_terminal(tmp_path):
    with chain(tmp_path,hold_nari=True) as c:
        sock=start_request(c);assert c.started.wait(2);sock.shutdown(socket.SHUT_RDWR);sock.close()
        assert c.closed.wait(2);until(lambda:not c.scheduler.snapshot()['busy'] and not c.gateway.requests._inflight)
        c.release.set()
        response=httpx.post(c.url+'/v1/captioned-speech',json=BODY,headers={'X-Clone-Token':TOKEN,'X-Request-ID':'fixture-http'},timeout=3)
        assert response.status_code==200 and len(c.requests)==2 and c.pipeline.calls==1


def test_rejected_auth_never_enters_synthesis_or_queue(tmp_path):
    with chain(tmp_path) as c:
        response=httpx.post(c.url+'/v1/captioned-speech',json=BODY,headers={'X-Clone-Token':'invalid'},timeout=2)
        assert response.status_code==401 and c.requests==[] and c.pipeline.calls==0


def test_new_http_consumer_waits_retiring_id_instead_of_reviving_or_failing():
    coalescer=RequestCoalescer();old=threading.Event();entered=threading.Event();finish=threading.Event();calls=[]
    def work():
        calls.append(1)
        if len(calls)==1:
            entered.set();finish.wait(2);check_cancelled()
        return 'new-audio'
    with ThreadPoolExecutor(2) as pool:
        first=pool.submit(bound,old,lambda:coalescer.execute('id','same',work,wait_timeout_s=2))
        assert entered.wait(1);old.set()
        second=pool.submit(coalescer.execute,'id','same',work,wait_timeout_s=2)
        time.sleep(.04);assert len(calls)==1 and not second.done()
        finish.set()
        with pytest.raises(ConsumerCancelled):first.result(1)
        assert second.result(1).value=='new-audio' and len(calls)==2
