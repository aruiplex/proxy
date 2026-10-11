#!/usr/bin/env python3
"""Verify real TLS timeout monitoring and isolated systemd restart limits."""
import argparse
import contextlib
import importlib.util
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path
from protocol_probe import certificate, origin
from routing_probe import FixtureProxy, free_port, serving

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('health', ROOT/'libexec/health.py')
health = importlib.util.module_from_spec(spec); spec.loader.exec_module(health)


def check(binary):
    with contextlib.ExitStack() as stack:
        root = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='health-evidence-fixture-')))
        cert, _, server_tls, _, _ = certificate(root)
        encrypted = origin(stack, server_tls); plain = origin(stack)
        node = stack.enter_context(serving(FixtureProxy(encrypted.server_address, plain.server_address)))
        port, control = free_port(), free_port()
        config = {'mixed-port':port,'bind-address':'127.0.0.1','external-controller':f'127.0.0.1:{control}',
                  'tun':{'enable':False},'dns':{'enable':False},'hosts':{'stream.test':'127.0.0.1'},
                  'proxies':[{'type':'http','name':'fixture','server':'127.0.0.1','port':node.server_address[1]}],
                  'proxy-groups':[{'name':'TEST','type':'select','proxies':['fixture']}],'rules':['MATCH,TEST']}
        (root/'config.yaml').write_text(json.dumps(config))
        (root/'proxy.conf').write_text(f'bin={binary}\ninstall_method=manual\ncontroller=127.0.0.1:{control}\n')
        env = dict(os.environ, CONF_DIR=str(root), CURL_CA_BUNDLE=str(cert))
        subprocess.run([ROOT/'proxy','start'],env=env,capture_output=True,check=True)
        stack.callback(subprocess.run,[ROOT/'proxy','stop'],env=env,capture_output=True,check=True)
        old_ca=os.environ.get('CURL_CA_BUNDLE'); os.environ['CURL_CA_BUNDLE']=str(cert)
        def restore_ca():
            if old_ca is None: os.environ.pop('CURL_CA_BUNDLE',None)
            else: os.environ['CURL_CA_BUNDLE']=old_ca
        stack.callback(restore_ca)
        targets={'fixture':f'https://stream.test:{encrypted.server_address[1]}/once'}
        state=None
        for _ in range(2): state=health.evaluate(health.observe(root,f'http://127.0.0.1:{port}',targets,1,()),state)
        checks={'real_verified_tls_probe':state['confirmed']=='healthy' and state['observation']['probes']['fixture']['certificate_verified']}
        node.stall.set()
        for _ in range(3): state=health.evaluate(health.observe(root,f'http://127.0.0.1:{port}',targets,1,()),state)
        checks['active_controller_with_persistent_business_timeout_detected']=state['confirmed']=='all_proxy_targets_failure' and state['observation']['process_alive'] and state['observation']['controller_ok']
        pid=int((root/'mihomo.pid').read_text())
        checks['business_timeout_does_not_restart_core']=pid==state['observation']['pid']
        node.stall.clear()
        for _ in range(2): state=health.evaluate(health.observe(root,f'http://127.0.0.1:{port}',targets,1,()),state)
        checks['real_target_recovery_detected']=state['notification'] is not None and state['confirmed']=='healthy'
        broken_env=dict(env,PATH=str(root))
        result=subprocess.run(['/usr/bin/python3',ROOT/'libexec/health.py','--root',root,'check'],env=broken_env,capture_output=True,text=True,check=True)
        checks['broken_probe_is_monitor_error_not_core_failure']=json.loads(result.stdout)['observed']=='monitor_error'
        unit='proxy-health-limit-fixture-'+str(os.getpid())+'.service'
        subprocess.run(['systemd-run','--user','--unit',unit,'--property=Restart=on-failure',
                        '--property=RestartSec=200ms','--property=StartLimitIntervalSec=30',
                        '--property=StartLimitBurst=2','/usr/bin/python3','-c','raise SystemExit(23)'],capture_output=True,check=True)
        try:
            deadline=time.monotonic()+8
            while time.monotonic()<deadline:
                evidence=health.systemd(unit)
                if evidence.get('restart_limit_observed') is True and int(evidence.get('NRestarts', 0)) >= 2 and any(e['status']==23 for e in evidence.get('recent_exits', [])): break
                time.sleep(0.1)
            checks['real_restart_limit_and_exit_status_recorded']=evidence.get('restart_limit_observed') is True and any(exit['status']==23 and exit['code']=='exited' for exit in evidence.get('recent_exits', [])) and int(evidence['NRestarts'])>=2
        finally:
            subprocess.run(['systemctl','--user','stop',unit],capture_output=True)
            subprocess.run(['systemctl','--user','reset-failed',unit],capture_output=True)
        signal_unit='proxy-health-signal-fixture-'+str(os.getpid())+'.service'
        subprocess.run(['systemd-run','--user','--unit',signal_unit,'/usr/bin/python3','-c','import os; os.kill(os.getpid(),9)'],capture_output=True,check=True)
        try:
            deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                signal=health.systemd(signal_unit)
                if any(e['code']=='killed' and e['status']==9 for e in signal.get('recent_exits', [])): break
                time.sleep(0.1)
            checks['real_exit_signal_recorded']=any(e['code']=='killed' and e['status']==9 for e in signal.get('recent_exits', []))
        finally:
            subprocess.run(['systemctl','--user','stop',signal_unit],capture_output=True)
            subprocess.run(['systemctl','--user','reset-failed',signal_unit],capture_output=True)
        return {'checks':checks,'scope':'isolated real TLS stalls/recovery and separate user service restart limit; no production fault injection'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel',type=Path,required=True); parser.add_argument('--output',type=Path)
    args=parser.parse_args(); report=check(args.kernel.resolve()); text=json.dumps(report,indent=2)
    if args.output: args.output.write_text(text+'\n')
    print(text); return 0 if all(report['checks'].values()) else 1


if __name__=='__main__': raise SystemExit(main())
