"""Pure orchestration contracts using explicitly synthetic CLI observations.

These tests execute no product binary, source model, SDK, decoder or renderer.
Their literal receipts/traces cannot establish native truth, media quality,
human listening or any production acceptance. Real verification stays intact.
"""
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import production_workflow as workflow
from knowledge_story import PHASES
from production_workflow import ProductionWorkflow, data, read, save, sha


class FakeCLI:
    """A declared state-machine fixture, never a claimed normal CLI run."""
    def __init__(self, state='queued', *, lease=None):
        self.state=state;self.lease=lease;self.calls=[]
        self.artifacts=[dict(path='UNIT-artifact-'+str(i),revision='UNIT-revision') for i in range(4)]
        self.quote=dict(id='UNIT-original-quote',provider='native',upper=dict(currency='CNY',amount=0))
        self.projects=[dict(id='UNIT-target',revisions=[dict(id='UNIT-revision')])]

    def status(self):
        job=dict(id='UNIT-original-job',lease=dict(expiresAt=self.lease) if self.lease else None)
        return dict(ok=True,job_id=job['id'],state=self.state,result=json.dumps(job),
            artifacts=deepcopy(self.artifacts) if self.state=='needs_review' else [])

    def invoke(self,command,body=None,dry=False,**kwargs):
        self.calls.append((command,deepcopy(body),dry,kwargs))
        if command=='projects list':return dict(result=json.dumps(self.projects))
        if command=='render estimate':return dict(result=json.dumps(self.quote))
        if command=='render submit':return dict(job_id='UNIT-original-job')
        if command=='jobs status':return self.status()
        if command=='worker run':self.state='interrupted'
        elif command=='jobs resume':self.state='queued'
        elif command=='jobs run':self.state='needs_review'
        else:raise AssertionError('unexpected synthetic operation '+command)
        return dict(ok=True,state=self.state)


def bare_host(cli):
    result=ProductionWorkflow.__new__(ProductionWorkflow)
    result.ws='UNIT-workspace';result.invoke=cli.invoke
    return result


def literal_sources(*, count=1, fps=24, rounds=3, start_tick=4, round_ticks=9):
    """Arbitrary complete observations, with no Python evaluation of rules."""
    scenes=[];declared=[];recorded=[]
    for index in range(count):
        identity='UNIT-source-'+str(index)
        model=dict(version=3,ruleTable={},rounds=rounds,startTick=start_tick,roundTicks=round_ticks,
            participants=[dict(id='UNIT-north'),dict(id='UNIT-south')])
        seed=101+index;last=start_tick+(rounds-1)*round_ticks+5
        events=[dict(round=i//6+1,phase=PHASES[i%6],tick=start_tick+i//6*round_ticks+i%6,
            actors=[dict(id='UNIT-north',resources=50+i),dict(id='UNIT-south',resources=200-i)])
            for i in range(rounds*6)]
        trace=dict(version=3,seed=seed,throughTick=last,inputDigest='a'*64,events=events,
            rounds=[dict(literalObservation=i) for i in range(rounds)],
            finalResources=deepcopy(events[-1]['actors']))
        frames=(last+1)*fps
        scenes.append(dict(id=identity,kind='规则模拟',locked=False,
            simulation=dict(knowledge=deepcopy(model),seed=seed),sourceStartFrame=0,speed=1,
            pauseFrames=0,durationFrames=frames,
            simulationRecording=dict(recordedFPS=fps,recordedDurationFrames=frames,recordedSpeed=1,
                recordedPauseFrames=0,knowledgeTrace=deepcopy(trace))))
        declared.append(dict(id=identity,scene_id=identity,model=deepcopy(model),seed=seed,
            start_frame=index*100,end_frame=(index+1)*100))
        recorded.append(dict(id=identity,model=deepcopy(model),seed=seed,trace=deepcopy(trace),
            startFrame=index*100,endFrame=(index+1)*100))
    project=dict(id='UNIT-native-source-project',workspaceID='UNIT-workspace',
        revisions=[dict(id='UNIT-recorded-revision',fps=fps,scenes=scenes)])
    state=dict(workspace_id=project['workspaceID'],source_project_id=project['id'],
        plan=dict(version=2,target=dict(fps=fps),sources=declared),
        recorded=dict(version=2,project_id=project['id'],revision='UNIT-recorded-revision',sources=recorded))
    return project,state


class SourceObservationContracts(unittest.TestCase):
    def verify(self,project,state):
        cli=FakeCLI();cli.projects=[project];host=bare_host(cli)
        host.FPS=state['plan']['target']['fps']
        host.verify_recorded_sources(state)
        return cli

    def test_one_or_three_sources_use_their_own_native_time_axis_and_observed_values(self):
        for count,fps,rounds,start,spacing in ((1,24,3,4,9),(3,60,1,11,7)):
            project,state=literal_sources(count=count,fps=fps,rounds=rounds,start_tick=start,round_ticks=spacing)
            before=deepcopy((project,state));cli=self.verify(project,state)
            self.assertEqual((project,state),before)
            self.assertEqual([r[0] for r in cli.calls],['projects list'])

    def test_caller_trace_model_seed_window_or_row_set_cannot_replace_persistent_observations(self):
        changes=[lambda s:s['recorded']['sources'][0]['trace']['events'][0]['actors'][0].update(resources=999),
            lambda s:s['recorded']['sources'][0]['model'].update(knowledgeLabel='UNIT-other'),
            lambda s:s['recorded']['sources'][0].update(seed=999),
            lambda s:s['recorded']['sources'][0].update(endFrame=999),
            lambda s:s['recorded']['sources'].append(deepcopy(s['recorded']['sources'][0])),
            lambda s:s['recorded'].update(sources=[])]
        for change in changes:
            with self.subTest(change=change):
                project,state=literal_sources();change(state)
                with self.assertRaisesRegex(ValueError,'complete persistent Core observations'):
                    self.verify(project,state)

    def test_a_persisted_partial_reordered_or_wrong_axis_trace_still_fails(self):
        changes=[lambda t:t.update(throughTick=11),lambda t:t['events'].pop(),
            lambda t:t['rounds'].pop(),lambda t:t['events'].reverse(),
            lambda t:t['events'][0].update(tick=0),lambda t:t.update(seed=0)]
        for change in changes:
            with self.subTest(change=change):
                project,state=literal_sources()
                trace=project['revisions'][0]['scenes'][0]['simulationRecording']['knowledgeTrace']
                change(trace);state['recorded']['sources'][0]['trace']=deepcopy(trace)
                with self.assertRaises(ValueError):self.verify(project,state)

    def test_frozen_source_revision_or_workspace_cannot_silently_advance(self):
        for change in (lambda p:p.update(workspaceID='UNIT-other'),
                       lambda p:p['revisions'].append(dict(id='UNIT-new-revision',fps=24,scenes=[]))):
            project,state=literal_sources();change(project)
            with self.assertRaises(ValueError):self.verify(project,state)


class SpeechAxisHookContracts(unittest.TestCase):
    def test_explicit_presentation_hook_owns_content_and_declared_frame_rate(self):
        with tempfile.TemporaryDirectory() as folder:
            host=ProductionWorkflow.__new__(ProductionWorkflow)
            host.home=Path(folder);host.SOURCE_NAMESPACE='UNIT-axis';host.FPS=24;host.ASPECT='9:16'
            host.voice=host.home/'UNIT-unread-voice';host.boundaries=host.home/'UNIT-unread-boundaries'
            host.ffmpeg=host.home/'UNIT-never-decoded';host.ffprobe=host.home/'UNIT-never-probed'
            host.narration=lambda:'UNIT original narration'
            host.model_sources=lambda:dict(alpha={},beta={},gamma={})
            # No author.pencil_plan API exists on this independent author.
            host.author=SimpleNamespace()
            observed=[];presentation=dict(UNIT='literal independently authored presentation')
            def authored(project,scene_ids):
                observed.append((project,scene_ids));return presentation
            host.presentation_for=authored
            fields={'inspection.container_duration':'4','inspection.decoded_duration':'4'}
            words=[dict(UNIT='literal boundary observation')]
            with patch.object(workflow,'inspect_mp3',return_value=dict(container_duration=4)), \
                 patch.object(workflow,'read_word_boundaries',return_value=words) as boundaries, \
                 patch.object(workflow,'retime_presentation',return_value=dict(UNIT='literal timing')) as retime:
                host.load_speech_axis(fields,host.home/'absent-axis.plist')
            boundaries.assert_called_once_with(host.boundaries,host.narration(),
                dict(decoded_duration=4.0,container_duration=4.0))
            retime.assert_called_once_with(presentation,words,'4',fps=24)
            self.assertEqual(set(observed[0][1]),{'alpha','beta','gamma'})
            self.assertEqual(observed[0][0]['revisions'][0]['fps'],24)


class OriginalJobContracts(unittest.TestCase):
    def test_live_original_lease_performs_no_execution_or_replacement(self):
        lease=(datetime.now(timezone.utc)+timedelta(hours=1)).isoformat()
        cli=FakeCLI('running',lease=lease)
        with patch('builtins.print'):
            self.assertIsNone(bare_host(cli).execute_job(cli.status()))
        self.assertEqual(cli.calls,[])

    def test_missing_lease_is_rejected(self):
        cli=FakeCLI('running')
        with self.assertRaisesRegex(ValueError,'finite lease'):bare_host(cli).execute_job(cli.status())
        self.assertEqual(cli.calls,[])

    def test_expired_lease_reclaims_and_resumes_only_the_original_job(self):
        cli=FakeCLI('running',lease='2000-01-01T00:00:00Z')
        result=bare_host(cli).execute_job(cli.status())
        self.assertEqual(result['job_id'],'UNIT-original-job')
        self.assertEqual(result['state'],'needs_review')
        writes=[(c,b) for c,b,_,_ in cli.calls if c!='jobs status']
        self.assertEqual([c for c,_ in writes],['worker run','jobs resume','jobs run'])
        self.assertEqual(writes[0][1],dict(workspace_id='UNIT-workspace',job_ids=['UNIT-original-job'],
            max_jobs=1,timeout_seconds=60,resume_interrupted=True,query_remote=False))
        self.assertTrue(all(b.get('job_id','UNIT-original-job')=='UNIT-original-job' for _,b in writes))

    def test_failed_or_interrupted_jobs_resume_before_running_the_same_identity(self):
        for state in ('failed','interrupted'):
            cli=FakeCLI(state);result=bare_host(cli).execute_job(cli.status())
            self.assertEqual(result['state'],'needs_review')
            self.assertEqual([c for c,_,_,_ in cli.calls if c!='jobs status'],['jobs resume','jobs run'])

    def test_recovery_hook_stops_at_queued_for_an_independently_selected_host_executor(self):
        cli=FakeCLI('interrupted');result=bare_host(cli).recover_job(cli.status())
        self.assertEqual(result['state'],'queued');self.assertEqual(result['job_id'],'UNIT-original-job')
        self.assertEqual([c for c,_,_,_ in cli.calls if c!='jobs status'],['jobs resume'])
        untouched=FakeCLI('queued');self.assertEqual(bare_host(untouched).recover_job(untouched.status())['state'],'queued')
        self.assertEqual(untouched.calls,[])

    def test_repeated_render_preserves_the_original_frozen_quote_and_job(self):
        with tempfile.TemporaryDirectory() as folder:
            cli=FakeCLI();host=bare_host(cli);host.home=Path(folder)
            save(host.home/'prepared.plist',dict(workspace_id='UNIT-workspace',project_id='UNIT-target',revision_id='UNIT-revision'))
            with patch('builtins.print'):host.render();host.render()
            self.assertEqual(read(host.home/'produced.plist')['job_id'],'UNIT-original-job')
            estimates=[c for c,_,_,_ in cli.calls if c=='render estimate']
            runs=[c for c,_,_,_ in cli.calls if c=='jobs run']
            submits=[b for c,b,_,_ in cli.calls if c=='render submit']
            self.assertEqual(len(estimates),1);self.assertEqual(len(runs),1)
            self.assertEqual(submits[0],submits[1]);self.assertTrue(submits[0]['quote']['confirmed'])

    def test_render_rejects_a_replacement_job_or_incomplete_deliverable_set(self):
        for issue in ('replacement','missing','extra'):
            with self.subTest(issue=issue), tempfile.TemporaryDirectory() as folder:
                cli=FakeCLI('needs_review');host=bare_host(cli);host.home=Path(folder)
                save(host.home/'prepared.plist',dict(workspace_id='UNIT-workspace',project_id='UNIT-target',revision_id='UNIT-revision'))
                if issue=='replacement':host.execute_job=lambda status:dict(cli.status(),job_id='UNIT-unauthorized-new-job')
                elif issue=='missing':cli.artifacts.pop()
                else:cli.artifacts.append(dict(path='UNIT-extra-artifact',revision='UNIT-revision'))
                with self.assertRaisesRegex(ValueError,'original normal job must produce four'):host.render()
                self.assertFalse((host.home/'produced.plist').exists())

    def test_real_invocation_cache_deduplicates_writes_but_refreshes_status(self):
        with tempfile.TemporaryDirectory() as folder:
            host=ProductionWorkflow.__new__(ProductionWorkflow)
            host.home=Path(folder);host.workspace=host.home/'workspace';host.binary=host.home/'UNIT-never-executed'
            host.SOURCE_NAMESPACE='UNIT-cache';host.pins={};host.calls=[]
            host.state=sqlite3.connect(':memory:')
            host.state.execute('CREATE TABLE requests (key TEXT PRIMARY KEY, response BLOB NOT NULL)')
            seen=[]
            def synthetic_process(argv,**kwargs):
                body=json.loads(kwargs['input']);seen.append((argv,body))
                response=dict(ok=True,request_id=body['request_id'],state='queued',job_id='UNIT-original-job')
                return subprocess.CompletedProcess(argv,0,data(response),b'')
            try:
                with patch.object(workflow.subprocess,'run',side_effect=synthetic_process):
                    body=dict(workspace_id='UNIT-workspace',quote=dict(id='UNIT-quote'))
                    first=host.invoke('render submit',body);second=host.invoke('render submit',body)
                    host.invoke('jobs status',dict(job_id=first['job_id']))
                    host.invoke('jobs status',dict(job_id=first['job_id']))
                self.assertEqual(first,second);self.assertEqual(len(seen),3)
                self.assertEqual(seen[0][0][:2],['rtk','proxy'])
                self.assertNotIn('request_id',body,'caller input must stay independent')
            finally:host.state.close()


class FixtureAuthor:
    def __init__(self,material):self.material=material
    def requirements(self):return dict(fixture=dict(path=self.material,sha256=sha(self.material.read_bytes())))


class FrozenInputWorkflow(ProductionWorkflow):
    VOICE_IDENTIFIER='UNIT-original-voice'
    SOURCE_NAMESPACE='UNIT-frozen-inputs'
    ASPECT='9:16';FPS=24;VIEWPORT=(720,1280)
    def narration(self):return 'UNIT literal original narration'
    def implementation_inputs(self):return (self.controller,self.helper)
    def controller_input(self):return self.controller
    def speech_receipt_fields(self):
        return dict(audio_sha256=sha(self.voice.read_bytes()),
            **{'word_boundaries.sha256':self.word_boundary_sha256(),'request.text':self.narration(),
               'request.voice':self.VOICE_IDENTIFIER,'request.configuration.boundary':'WordBoundary'})
    def load_speech_axis(self,fields,axis):
        # Literal timing only. This fixture bypass is never production evidence.
        return dict(frames=96,axis=dict(fps=self.FPS,duration_seconds='4'))


class FrozenInputContracts(unittest.TestCase):
    def setUp(self):
        self.folder=tempfile.TemporaryDirectory();self.root=Path(self.folder.name).resolve()
        for name in ('binary','voice.mp3','voice.source.md','boundaries','material','helper.py','controller.py','tool-ffmpeg','tool-ffprobe'):
            (self.root/name).write_bytes(('UNIT literal '+name).encode())
        self.args=SimpleNamespace(home=self.root/'home',output=self.root/'output',binary=self.root/'binary',
            binary_sha256=sha((self.root/'binary').read_bytes()),voice=self.root/'voice.mp3',
            boundaries=self.root/'boundaries',previous_inputs_sha256=None)
        self.instances=[]

    def tearDown(self):
        for instance in self.instances:
            if hasattr(instance,'state'):instance.state.close()
        self.folder.cleanup()

    def construct(self):
        result=FrozenInputWorkflow.__new__(FrozenInputWorkflow);self.instances.append(result)
        result.AUTHOR=FixtureAuthor(self.root/'material')
        result.controller=self.root/'controller.py';result.helper=self.root/'helper.py'
        with patch.object(workflow.shutil,'which',side_effect=lambda name:str(self.root/('tool-'+name))):
            result.__init__(self.args)
        return result

    def test_freeze_includes_engine_actual_caller_author_inputs_assets_and_original_speech(self):
        instance=self.construct();pins=read(instance.home/'inputs.plist')
        expected=[Path(workflow.__file__).resolve(),Path(__file__).resolve(),self.root/'helper.py',
            self.root/'controller.py',self.root/'material',self.root/'voice.mp3',
            self.root/'voice.source.md',self.root/'boundaries']
        self.assertTrue(all(str(p) in pins and pins[str(p)]==sha(p.read_bytes()) for p in expected))
        self.assertEqual(self.construct().pins,instance.pins)

    def test_only_explicit_retained_controller_change_may_upgrade(self):
        first=self.construct();inputs=first.home/'inputs.plist';original=read(inputs)
        provenance=first.home/'speech-provenance.plist';old_proof=read(provenance);proof_hash=sha(provenance.read_bytes())
        self.args.previous_inputs_sha256=sha(inputs.read_bytes())
        (first.home/'original-controller.py').write_bytes((self.root/'controller.py').read_bytes())
        (self.root/'controller.py').write_bytes(b'UNIT explicit revised controller')
        second=self.construct()
        self.assertNotEqual(read(inputs)[str(self.root/'controller.py')],original[str(self.root/'controller.py')])
        self.assertEqual({p for p in original if original[p]!=read(inputs)[p]}, {str(second.controller)})
        self.assertEqual(read(provenance),dict(old_proof,inputs_sha256=sha(inputs.read_bytes())))
        self.assertEqual(read(first.home/'speech-provenance-history'/(proof_hash+'.plist')),old_proof)

    def test_speech_provenance_binds_the_actual_axis_original_inputs_and_same_request_receipt(self):
        first=self.construct();home=first.home
        self.assertEqual(read(home/'speech-provenance.plist'),dict(version=1,kind='observed-sdk-words',
            axis_sha256=sha((home/'speech-axis.plist').read_bytes()),
            inputs_sha256=sha((home/'inputs.plist').read_bytes()),
            voice_sha256=sha((self.root/'voice.mp3').read_bytes()),
            source_receipt_sha256=sha((self.root/'voice.source.md').read_bytes()),
            word_boundaries_sha256=sha((self.root/'boundaries').read_bytes())))
        inputs=read(home/'inputs.plist')
        self.assertNotIn(str(home/'speech-axis.plist'),inputs)
        self.assertNotIn(str(home/'speech-provenance.plist'),inputs)
        self.assertIn(str(home/'speech-provenance.plist'),first.pins)

    def test_extra_helper_or_asset_changes_are_not_controller_upgrades(self):
        for name in ('helper.py','material'):
            with self.subTest(name=name):
                first=self.construct();inputs=first.home/'inputs.plist'
                self.args.previous_inputs_sha256=sha(inputs.read_bytes())
                old=(self.root/name).read_bytes();(self.root/name).write_bytes(old+b' changed')
                try:
                    with self.assertRaisesRegex(ValueError,'only an explicit retained-controller upgrade'):self.construct()
                finally:(self.root/name).write_bytes(old)

    def test_old_home_missing_the_new_engine_pin_is_never_silently_migrated(self):
        first=self.construct();inputs=first.home/'inputs.plist';legacy=read(inputs)
        legacy.pop(str(Path(workflow.__file__).resolve()))
        inputs.write_bytes(plistlib.dumps(legacy,fmt=plistlib.FMT_BINARY,sort_keys=True))
        self.args.previous_inputs_sha256=sha(inputs.read_bytes())
        with self.assertRaisesRegex(ValueError,'only an explicit retained-controller upgrade'):self.construct()

    def test_changed_pinned_bytes_fail_before_even_a_cached_operation(self):
        first=self.construct();(self.root/'helper.py').write_bytes(b'UNIT mutated helper')
        with patch.object(workflow.subprocess,'run') as execute:
            with self.assertRaisesRegex(ValueError,'frozen source, voice or runtime changed'):
                first.invoke('render submit',dict(quote='UNIT-original'))
            execute.assert_not_called()


if __name__=='__main__':unittest.main()
