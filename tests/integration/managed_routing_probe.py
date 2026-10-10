#!/usr/bin/env python3
"""Exercise management, generated policy, quality and feedback on a real core.

Loopback-only origin and outbound fixtures; temporary state, no subscriptions,
no account credentials, no TUN, no changes to production service/settings.
"""
import argparse
import contextlib
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path

from protocol_probe import certificate, origin
from routing_probe import FixtureProxy, Stream, free_port, serving

ROOT=Path(__file__).resolve().parents[2]


def check(binary, official):
    with contextlib.ExitStack() as stack:
        directory=Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='managed-routing-')))
        home=directory/'home';home.mkdir()
        cert,key,tls_server,tls_client,fingerprint=certificate(directory)
        encrypted=origin(stack,tls_server);health=origin(stack)
        nodes={name:stack.enter_context(serving(FixtureProxy(encrypted.server_address,health.server_address))) for name in ['nodeA','nodeB']}
        for node in nodes.values(): node.failure_scope='target'
        port,controller=free_port(),free_port()
        config={'mixed-port':port,'bind-address':'127.0.0.1','external-controller':f'127.0.0.1:{controller}',
                'secret':'fixture-only','tun':{'enable':False},'dns':{'enable':False},'hosts':{'stream.test':'127.0.0.1','health.test':'127.0.0.1'},
                'proxies':[{'name':name,'type':'http','server':'127.0.0.1','port':node.server_address[1]} for name,node in nodes.items()],
                'proxy-groups':[{'name':'PROXY','type':'select','proxies':list(nodes)}],
                'rules':['DOMAIN-SUFFIX,lan,DIRECT','MATCH,PROXY']}
        (home/'config.yaml').write_text(json.dumps(config))
        (home/'proxy.conf').write_text(f'bin={official}\ninstall_method=manual\n')
        prefs=directory/'preferences.json';prefs.write_text(json.dumps({'schema':1,'enabled':True,'direct_first':False,
                   'preferred_region':'SG','regions':{'nodeA':'SG','nodeB':'JP'},'failure_cooldown':300}))
        candidate=directory/'candidate.json'
        environment=dict(os.environ,CONF_DIR=str(home),PYTHONDONTWRITEBYTECODE='1')
        def cli(*args,success=True):
            run=subprocess.run([str(ROOT/'proxy'),*map(str,args)],env=environment,text=True,capture_output=True,timeout=40)
            if (run.returncode==0)!=success: raise AssertionError(run.stdout+run.stderr)
            return run.stdout
        original=(home/'config.yaml').read_bytes()
        cli('auto','prepare','--preferences',prefs,'--output',candidate)
        checks={'render_does_not_change_live_config':(home/'config.yaml').read_bytes()==original,
                'explicit_direct_rule_preserved':'DOMAIN-SUFFIX,lan,DIRECT' in candidate.read_text()}
        cli('kernel','prepare','--bin',binary,'--source','fixture-prototype','--config',candidate,'--preferences',prefs)
        cli('kernel','activate')
        cli('start');stack.callback(cli,'stop')
        first=Stream(port,encrypted.server_address[1],tls_client);stack.callback(first.close)
        tls_version=first.conn.version()
        target=f'stream.test:{encrypted.server_address[1]}'
        quality=json.loads(cli('quality','--json'))
        first_route=max(quality['records'],key=lambda r:r['selection'])['node']
        checks['generated_group_routes_real_verified_tls']=first_route=='nodeA' and first.progressing()
        cli('feedback',target,'--reason','timeout')
        second=Stream(port,encrypted.server_address[1],tls_client);stack.callback(second.close)
        rows=json.loads(cli('quality','--target',target,'--json'))['records']
        checks['cli_feedback_changes_next_route']=max(rows,key=lambda r:r['selection'])['node']=='nodeB'
        checks['cli_feedback_keeps_healthy_tls_stream']=first.progressing()
        cli('kernel','activate',success=False)
        checks['running_activation_refused_without_closing_streams']=first.progressing() and second.progressing()
        time.sleep(0.35)
        nodes['nodeB'].reject.set()
        try:
            third=Stream(port,encrypted.server_address[1],tls_client);stack.callback(third.close)
        except Exception as error:
            raise RuntimeError('fixture dial failed: ' + cli('quality','--json') + (home/'mihomo.log').read_text()[-6000:]) from error
        events=json.loads(cli('quality','--json'))['events']
        checks['dial_fault_returns_to_working_route']=any(e['kind']=='dial-failed' and e['node']=='nodeB' for e in events) and third.progressing()
        checks['sibling_tls_streams_survive_dial_fault']=first.progressing() and second.progressing()
        # Refresh replay changes only a staged candidate until normal validation.
        refreshed=directory/'refreshed.json';refreshed.write_text(json.dumps(config))
        subprocess.run(['bash','-c','SCRIPT_DIR=$1; source "$1/lib/common.sh"; source "$1/lib/auto.sh"; _adaptive_replay "$2"','fixture',str(ROOT),str(refreshed)],env=environment,check=True)
        checks['refresh_replays_portable_policy']=json.loads(refreshed.read_text())['rules'][-2]=='NETWORK,tcp,AUTO-ADAPTIVE' and json.loads(refreshed.read_text())['rules'][-1]=='MATCH,PROXY'
        cli('stop')
        cli('kernel','rollback')
        state=json.loads(cli('kernel','status','--json'))
        checks['rollback_restores_official_and_original_config']=state['active']['version']=='v1.19.32' and (home/'config.yaml').read_bytes()==original
        checks['rollback_removes_new_preferences']=not (home/'adaptive.json').exists()
        return {'checks':checks,'tls_version':tls_version,'scope':'temporary managed core, generated policy and verified loopback TLS; no real AI requests'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel',required=True,type=Path)
    parser.add_argument('--official',required=True,type=Path)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    report=check(args.kernel.resolve(),args.official.resolve())
    text=json.dumps(report,indent=2)
    print(text)
    if args.output: args.output.write_text(text+'\n')
    return 0 if all(report['checks'].values()) else 1


if __name__=='__main__': raise SystemExit(main())
