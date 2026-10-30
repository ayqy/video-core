#!/usr/bin/env python3
"""Finite real free-CLI atlas chain using a clearly synthetic public fixture.

No model, credentials, business artwork, paid plugin, manual approval or device
is used. The two-color image tests source regions; it is not story artwork or
evidence of a completed production video. All state lives in runner scratch.
"""
from __future__ import annotations
import argparse
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import uuid
import zlib


def png():
    def chunk(kind,raw):
        return struct.pack('>I',len(raw))+kind+raw+struct.pack('>I',zlib.crc32(kind+raw)&0xffffffff)
    scan=b''.join(b'\0'+b'\xff\0\0\xff'*32+b'\0\xff\0\xff'*32 for _ in range(32))
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',64,32,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(scan))+chunk(b'IEND',b'')


DECODER=r'''
import Foundation
import AVFoundation
import CoreVideo
let url=URL(fileURLWithPath:CommandLine.arguments.last!)
let asset=AVURLAsset(url:url)
let tracks=asset.tracks(withMediaType:.video)
guard tracks.count==1 else {fatalError("one actual video stream required")}
let reader=try AVAssetReader(asset:asset)
let output=AVAssetReaderTrackOutput(track:tracks[0],outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
reader.add(output)
guard reader.startReading() else {fatalError("native full-frame decoding failed")}
var count=0
var colors:[String]=[]
while let sample=output.copyNextSampleBuffer() {
    guard let pixel=CMSampleBufferGetImageBuffer(sample) else {fatalError("decoded video buffer missing")}
    CVPixelBufferLockBaseAddress(pixel,.readOnly)
    let width=CVPixelBufferGetWidth(pixel),height=CVPixelBufferGetHeight(pixel),stride=CVPixelBufferGetBytesPerRow(pixel)
    guard width==1280,height==720,let base=CVPixelBufferGetBaseAddress(pixel) else {fatalError("actual output geometry changed")}
    func color(_ x:Int,_ y:Int)->String {
        let p=base.assumingMemoryBound(to:UInt8.self).advanced(by:y*stride+x*4)
        let r=Int(p[2]),g=Int(p[1])
        return r>g+30 && r>100 ? "red":g>r+30 && g>100 ? "green":"other"
    }
    colors.append(color(640,360))
    guard color(256,360)=="green" else {fatalError("static atlas crop rendered the wrong actual pixels")}
    CVPixelBufferUnlockBaseAddress(pixel,.readOnly)
    count+=1
}
guard reader.status == .completed,count==30 else {fatalError("complete thirty-frame stream required")}
for i in 0..<30 {
    guard colors[i] == (i<10 || i>=20 ? "red":"green") else {fatalError("atlas source-clock samples changed after normal split")}
}
print("native_decoded_frames=30 animated_pixels=red_green_red static_crop=green")
'''


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--scratch',type=Path,required=True)
    args=parser.parse_args()
    binary=args.binary.resolve(strict=True)
    root=Path(tempfile.mkdtemp(prefix='layer-atlas-',dir=args.scratch.resolve(strict=True)))
    work=root/'workspace';restored=root/'restored';calls=0
    def call(label,command,body=None,*,dry=False,target=work,ok=True,timeout=40):
        nonlocal calls
        data=deepcopy(body or {})
        data.setdefault('request_id',str(uuid.uuid5(uuid.NAMESPACE_URL,str(root)+'/'+label)))
        argv=[str(binary),*command.split(),'--workspace',str(target),'--input','-']
        if dry:argv.append('--dry-run')
        response=subprocess.run(argv,input=json.dumps(data),text=True,capture_output=True,timeout=timeout)
        value=json.loads(response.stdout)
        assert not response.stderr,(label,'unexpected CLI diagnostics')
        assert value.get('ok') is ok and value.get('request_id')==data['request_id'],(label,value.get('state'))
        assert (response.returncode==0) is ok,(label,response.returncode)
        calls+=1
        return value
    def result(value):
        raw=value['result'];return json.loads(raw) if isinstance(raw,str) else raw
    def project(wid,pid,*,target=work):
        return next(p for p in result(call('query-'+str(calls),'projects list',dict(workspace_id=wid),target=target)) if p['id']==pid)
    try:
        image=root/'synthetic-atlas.png';image.write_bytes(png());image_sha=hashlib.sha256(image.read_bytes()).hexdigest()
        catalog=result(call('discover-current-schema','schema'))
        assert 'LayerImageSequence' in json.dumps(catalog) and 'sourceRect' in json.dumps(catalog)
        wid=result(call('create-workspace','workspaces create',dict(name='公开合成图集最小链')))['id']
        scope=dict(workspace_id=wid)
        asset=result(call('import-fixture','assets import',dict(scope,path=str(image))))
        assert asset['hash']==image_sha and asset['mediaType'].startswith('image')
        proof=dict(id=str(uuid.uuid4()),workspaceID=wid,assetID=asset['id'],title='公开CI合成像素夹具',
                   owner='Public CI synthetic fixture',source='Generated in this finite smoke test from fixed literal RGBA bytes',
                   claim='Synthetic two-color test pixels only; no production art, provider or rights review is represented',
                   commercialAllowed=False,uploadConsent=False,verified=True,
                   checkedAt=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
        call('bind-fixture-proof','evidence add',dict(scope,evidence=proof))
        created=call('create-content-project','script create',dict(scope,aspect='16:9',knowledge='同一图集的真实裁区。',
                     demonstration='拆分保留原源帧。',hook='如何保留源区域？'))
        pid=created['project_id'];current=project(wid,pid);revision=current['revisions'][-1]
        scene=deepcopy(revision['scenes'][0]);sid=scene['id']
        scene.update(kind='图文讲解',title='公开合成图集源帧',body='同一原图按源帧换区，静态裁区保持。',narration='',durationFrames=30,sourceStartFrame=0,
                     speed=1,preservePitch=True,pauseFrames=0,captions=[],classicArtworkRequired=False,
                     evidenceIDs=[proof['id']],showPrice=False,keyframes=[],x=.5,y=.5,scale=1)
        for key in ('voice','speechPlan','cartoonRig','cartoonPresenter','cartoonPerformance','classicArtwork',
                    'gameWorld','simulationRecording','simulationPresentation','paperPresentation'):
            scene.pop(key,None)
        left=dict(x=0,y=0,width=.5,height=1);right=dict(x=.5,y=0,width=.5,height=1)
        def layer(identity,x,width,height):
            return dict(id=identity,kind='图片',text='',assetID=asset['id'],x=x,y=.5,width=width,height=height,
                        color='FFFFFF',opacity=1,startFrame=0,endFrame=30,locked=False,keyframes=[])
        animated=layer('actual-atlas',.5,.3,.3)
        animated['imageSequence']=dict(version=1,frames=[dict(startFrame=a,endFrame=b,sourceRect=r)
                                                       for a,b,r in ((0,10,left),(10,20,right),(20,30,left))])
        static=layer('static-prop',.2,.2,.2);static['sourceRect']=right
        scene['layers']=[animated,static]
        edits=[dict(replaceScene={'_0':sid,'_1':scene})]+[dict(removeScene={'_0':s['id']}) for s in revision['scenes'][1:]]
        body=dict(scope,project_id=pid,base_revision=revision['id'],edits=edits,text='公开合成裁区与真实源帧最小链')
        call('dry-authored-image','edit apply',body,dry=True)
        assert project(wid,pid)['revisions'][-1]['id']==revision['id']
        call('apply-authored-image','edit apply',body)
        applied=project(wid,pid);rid=applied['revisions'][-1]['id']
        bad=deepcopy(scene);bad['layers'][0]['sourceRect']=left
        call('reject-ambiguous-image','edit apply',dict(scope,project_id=pid,base_revision=rid,
             edits=[dict(replaceScene={'_0':sid,'_1':bad})]),dry=True,ok=False)
        assert project(wid,pid)['revisions'][-1]['id']==rid
        split=dict(scope,project_id=pid,base_revision=rid,edits=[dict(splitScene={'_0':sid,'_1':15})])
        call('dry-source-split','edit apply',split,dry=True)
        call('apply-source-split','edit apply',split)
        current=project(wid,pid);revision=current['revisions'][-1]
        assert len(revision['scenes'])==2 and sum(s['durationFrames'] for s in revision['scenes'])==30
        assert [s['layers'][0]['imageSequence']['sourceOffsetFrames'] for s in revision['scenes']]==[0,15]
        assert all(s['layers'][0]['imageSequence']['frames']==animated['imageSequence']['frames'] for s in revision['scenes'])
        assert all(s['layers'][1]['sourceRect']==right for s in revision['scenes'])
        quote=result(call('estimate-local-only','render estimate',dict(scope,project_id=pid)))
        assert quote['provider']=='native' and quote['upper']['amount']==0 and not quote['confirmed']
        quote['confirmed']=True
        submitted=call('submit-one-local-job','render submit',dict(scope,project_id=pid,quote=quote))
        jid=submitted['job_id']
        made=call('run-original-local-job','jobs run',dict(scope,job_id=jid),timeout=180)
        assert made['state']=='needs_review' and len(made['artifacts'])==4
        movie=next(Path(a['path']) for a in made['artifacts'] if Path(a['path']).suffix=='.mp4')
        for item in made['artifacts']:
            raw=Path(item['path']).read_bytes()
            assert len(raw)==item['bytes'] and hashlib.sha256(raw).hexdigest()==item['sha256']
        decoder=root/'decode.swift';decoder.write_text(DECODER)
        decoded=subprocess.run(['swift',str(decoder),str(movie)],text=True,capture_output=True,timeout=90)
        assert decoded.returncode==0,decoded.stderr[-1000:]
        assert 'native_decoded_frames=30 animated_pixels=red_green_red static_crop=green' in decoded.stdout
        backup=call('normal-backup','backup create')
        assert len(backup['artifacts'])==1
        archive_path=Path(backup['artifacts'][0]['path']);archive=plistlib.loads(archive_path.read_bytes())
        assert hashlib.sha256(archive['snapshot']).hexdigest()==archive['digest']
        call('independent-normal-restore','backup restore',dict(path=str(archive_path)),target=restored)
        roundtrip=project(wid,pid,target=restored)
        assert roundtrip['revisions']==current['revisions']
        status=call('restored-original-job','jobs status',dict(scope,job_id=jid),target=restored)
        assert status['state']=='needs_review' and len(status['artifacts'])==4
        assert result(call('restored-doctor','doctor',target=restored))['database']['validated']
        print('layer_image_sequence_smoke=passed actual_cli_calls='+str(calls)+' native_decoded_frames=30'
              +' source_window_split=preserved static_crop=green backup_restore=passed synthetic_fixture_only=true review=false')
    finally:
        shutil.rmtree(root)


if __name__=='__main__':main()
