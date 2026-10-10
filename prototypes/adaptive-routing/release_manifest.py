#!/usr/bin/env python3
"""Export a local manifest for the exact validated prototype binary."""
import argparse
import hashlib
import json
from pathlib import Path


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    root=Path(__file__).resolve().parent
    baseline=json.loads((root/'baseline.json').read_text())
    validated=json.loads((root/'results.json').read_text())
    binary=args.binary.resolve()
    with binary.open('rb') as stream:
        sha=hashlib.sha256()
        for chunk in iter(lambda:stream.read(1024*1024),b''):sha.update(chunk)
    if validated['baseline'] != baseline or sha.hexdigest() != validated['binary_sha256']:
        parser.error('binary does not match the saved validated build; rebuild/revalidate first')
    os_name,arch=baseline['platform_validated'].split('/')
    manifest={'schema':1,'source':{'id':'aruiplex/proxy-adaptive','kind':'custom'},'version':baseline['version'],
              'platform':{'os':os_name,'arch':arch},'asset':{'path':str(binary),'sha256':sha.hexdigest(),'compression':'none'},
              'build':baseline}
    with args.output.open('x') as output:
        output.write(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    print(str(args.output.resolve()))


if __name__=='__main__':main()
