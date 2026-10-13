"""Rebuild the cross-channel diagnosis from sanitized local evidence only."""
from pathlib import Path
from collections import Counter
from datetime import datetime
import json,hashlib
P=Path(__file__).resolve().parent
def read(name):return json.loads((P/name).read_text())
cross=read('cross-channel-evidence.json');metrics=read('runtime-metrics.json');identity=read('runtime-identity.json')
agent=cross['agent']['events'];tunnels=cross['tunnels']['events']
spooled=[r for r in agent if r['event']=='report_spooled'];delayed=[r for r in metrics['rows'] if (datetime.fromisoformat(r['received_at'])-datetime.fromisoformat(r['observed_at'])).total_seconds()>5]
assert len(spooled)==9 and all(r['reason']=='network_error' for r in spooled)
assert len(delayed)==3 and metrics['contentRange']=='0-40/41'
assert all(r['metrics']['tts_pid']==507638 and r['metrics']['tts_service_up'] is True and r['metrics']['tts_restart_count']==0 for r in delayed)
assert all(r['metrics']['public_api_tcp_reachable_from_node'] is False and r['metrics']['gpu_util_max_pct']==0 for r in delayed)
assert identity['processes'][0]['flags']['--tts-port']=='18880'
assert identity['processes'][0]['flags']['--public-api-host']=='api.castreader.ai'
connect=[r for r in tunnels if r['event']=='edge_connect_failed']
assert len(connect)==15 and all(r['remotePort']==7844 and r['errorClass']=='tcp_connect_timeout' for r in connect)
summary={'verdict':'Evidence supports an incident affecting inbound and outbound connectivity of the US GPU instance while the TTS process remained running. Exact host/router/NAT/firewall failure remains unconfirmed.','instanceId':'42998411','machineId':9236,'windowUTC':{'start':'2026-09-08T17:40:00Z','endExclusive':'2026-09-08T18:30:00Z'},'agent':{'reportNetworkFailures':len(spooled),'firstFailedReportUTC':spooled[0]['at'],'lastFailedReportUTC':spooled[-1]['at'],'staleReportsDropped':sum(r.get('dropped_stale',0) for r in agent),'recoveryEvents':[r for r in agent if r['event']=='spool_flush' and r.get('sent',0)>0]},'tunnels':{'independentTunnelKeys':len({r['tunnelKey'] for r in tunnels}),'edgeConnectFailureEvents':len(connect),'destinationPeerKeys':len({r['remotePeerKey'] for r in connect}),'firstConnectFailureUTC':connect[0]['atUTC'],'lastConnectFailureUTC':connect[-1]['atUTC'],'recoveries':[r for r in tunnels if r['event']=='edge_registered']},'retainedIncidentMetrics':[{'sampleWindowStartUTC':r['window_started_at'],'sampleWindowEndUTC':r['window_ended_at'],'receivedAtUTC':r['received_at'],'samples':r['sample_count'],'metrics':r['metrics'],'collectorErrors':r['collector_errors']} for r in delayed],'providerLogCoverage':read('provider-daemon-unfiltered.json'),'interpretationLimits':['No historical host kernel/router/conntrack telemetry is available in the returned provider export.','No-current-reboot and live running status alone do not prove historical availability; delayed sampled metrics and other-process logs provide incident evidence.','established_connections covers model port 18880 only, not every connection on the host.','port_8880_listening=null is not a stopped model on the configured port 18880.','cpu_load_1m is load average, not CPU percentage.','The three delayed windows do not reconstruct the six stale reports deleted by the agent.']}
(P/'summary.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False)+'\n')
(P/'evidence-hashes.json').write_text(json.dumps({f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in P.iterdir() if f.is_file() and f.name!='evidence-hashes.json'},indent=2)+'\n')
print(json.dumps({'verification':'passed','retainedIncidentMetricWindows':len(delayed),'spooledReports':len(spooled),'tcpEdgeConnectFailures':len(connect),'staleReportsDropped':summary['agent']['staleReportsDropped']}))
