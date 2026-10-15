"""Bounded delegation and persisted continuation checks through real hook calls."""

from __future__ import annotations

import json

import test_growth_recovery as recovery
import test_local_installation as fixtures


class WorkflowContinuationTests(fixtures.FixtureTest):
    reset_state = recovery.GrowthRecoveryTests.reset_state
    state = recovery.GrowthRecoveryTests.state
    hook = recovery.GrowthRecoveryTests.hook
    read = recovery.GrowthRecoveryTests.read
    delegate = recovery.GrowthRecoveryTests.delegate

    def setUp(self):
        super().setUp()
        self.copy_sources()
        identity = self.clone / 'orchestration' / 'project_identity.py'
        identity.write_text(identity.read_text() + '\n_find_git_root = lambda cwd: None\n')
        self.paths = ('stockflow/core.py','stockflow/util.py','tests/test_core.py')
        for relative in self.paths:
            path = self.project / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('synthetic fixture\n')
        self.reset_state([], recovery=False)

    def test_initial_monolith_is_denied_but_two_objective_creation_is_allowed(self):
        broad = self.delegate(['stockflow/**','tests/**','README.md'],
                              ['catalog','orders','apply','report','unittest_suite'], recovery=False)
        self.assertEqual(broad['permissionDecision'],'deny',broad)
        self.assertIn('initial',broad['permissionDecisionReason'].lower())
        self.assertEqual(self.state()['algorithm_scope_objectives'],['model','tests'])
        premature=self.hook('PreToolUse',tool_name='agent',tool_input={'subagent_type':'test-agent','prompt':'Verify prematurely','run_in_background':False})
        self.assertEqual(premature['hookSpecificOutput']['permissionDecision'],'deny')
        self.assertIn('Implementation is incomplete',premature['hookSpecificOutput']['permissionDecisionReason'])
        self.assertIsNone(self.state()['pending_admission'])
        small = self.delegate(['new_package/**','new_tests/**'],['package','tests'],recovery=False)
        self.assertEqual(small['permissionDecision'],'allow',small)
        self.assertEqual(self.state()['algorithm_scope_files'],['new_package/**','new_tests/**'])

    def test_repair_is_category_bounded_and_only_real_submission_resumes(self):
        self.reset_state(['stockflow/**'])
        before = self.state()
        for attempt in range(3):
            denied = self.delegate(['stockflow/core.py'], ['model::small'])
            self.assertEqual(denied['permissionDecision'], 'deny')
        self.assertTrue(denied['permissionDecisionReason'].startswith('LOCALAI_WORKFLOW_INCOMPLETE:'))
        paused = self.state()
        self.assertTrue(paused['delegation_blocked_reason'])
        for prompt in ('', 'Internal Stop continuation'):
            self.hook('UserPromptSubmit', prompt=prompt)
            self.assertEqual(self.state()['delegation_blocked_reason'], paused['delegation_blocked_reason'])
        self.hook('UserPromptSubmit', prompt='Resume carefully', submitted_prompt='Resume carefully')
        resumed = self.state()
        self.assertFalse(resumed['delegation_blocked_reason'])
        for key in ('growth_recovery_anchor_objectives','growth_recovery_failed_files','growth_recovery_guard_active'):
            self.assertEqual(resumed[key], before[key])

    def test_new_read_is_progress_duplicate_read_is_not_and_parameter_errors_block_stop(self):
        self.reset_state(['stockflow/**'])
        self.delegate(['stockflow/core.py'], ['model::small'])
        self.assertEqual(self.state()['delegation_failure_total'], 1)
        self.read('stockflow/core.py')
        self.assertEqual(self.state()['delegation_failure_total'], 0)
        self.delegate(['stockflow/core.py'], ['model::small'])
        self.read('stockflow/core.py')
        self.assertEqual(self.state()['delegation_failure_total'], 1)
        self.reset_state([], recovery=False)
        self.hook('PostToolUseFailure', tool_name='agent', tool_input={'todo_id':22},
                  error='LOCALAI_AGENT_PARAMETER_ERROR: todo_id must be a string')
        stopped = self.hook('Stop')
        self.assertEqual(stopped['decision'], 'block', stopped)
        self.assertFalse(self.state()['turn_closed'])

    def test_root_reinjection_survives_history_replacement_and_session_end(self):
        self.reset_state(['stockflow/**'])
        self.read('stockflow/core.py')
        before = self.state()
        # The runtime callback has no old carrier/history; authoritative disk state must suffice.
        for event in ('SessionStart','UserPromptSubmit'):
            output = self.hook(event, prompt='', **({'source':'compact'} if event == 'SessionStart' else {}))
            self.assertIn('AUTHORITATIVE_GROWTH_RECOVERY_STATE=', json.dumps(output))
        ended = self.hook('SessionEnd')
        self.assertIn('resumable', ended.get('systemMessage','').lower())
        resumed = self.hook('SessionStart')
        self.assertIn('AUTHORITATIVE_GROWTH_RECOVERY_STATE=', json.dumps(resumed))
        after = self.state()
        for key in before:
            if key not in ('updated_at','resumable_end_reason'): self.assertEqual(after[key], before[key], key)
        self.assertTrue(after['resumable_end_reason'])
        self.assertTrue(ended['systemMessage'].startswith('LOCALAI_WORKFLOW_INCOMPLETE:'))
        self.hook('SubagentStart', agent_type='algorithm-agent', agent_id='child')
        child = self.hook('UserPromptSubmit', prompt='')
        self.assertNotIn('AUTHORITATIVE_GROWTH_RECOVERY_STATE=', json.dumps(child))

    def test_nonfinal_success_is_parent_visible_and_next_slice_remains_guarded(self):
        self.reset_state(list(self.paths))
        for path in self.paths: self.read(path)
        accepted = self.delegate(['stockflow/core.py'], ['model::small'])
        self.assertEqual(accepted['permissionDecision'], 'allow', accepted)
        self.hook('SubagentStart', agent_type='algorithm-agent', agent_id='slice')
        result = self.hook('SubagentStop', agent_type='algorithm-agent', agent_id='slice',
                           last_assistant_message='PASS\nSlice succeeded.\nMEMORY: NONE')
        self.assertTrue(result['systemMessage'].startswith('LOCALAI_ROOT_CONTINUATION:'), result)
        self.assertTrue(self.state()['growth_recovery_guard_active'])
        hint = json.loads(result['systemMessage'].split('AUTHORITATIVE_GROWTH_RECOVERY_STATE=',1)[1])
        example = hint['example']
        self.assertTrue(example['ALGORITHM_SCOPE']['objectives'][0].startswith('tests::'))
        accepted_example = self.delegate(example['ALGORITHM_SCOPE']['files'],example['ALGORITHM_SCOPE']['objectives'],
                                         **example['GROWTH_RECOVERY'])
        self.assertEqual(accepted_example['permissionDecision'],'allow',accepted_example)
        second = self.delegate(['stockflow/util.py'], ['tests::small'])
        self.assertEqual(second['permissionDecision'], 'deny', second)
        self.assertEqual(self.hook('Stop')['decision'], 'block')

    def test_initial_file_budget_and_sequential_small_normal_slices(self):
        for index in range(17):
            (self.project / 'stockflow' / f'file{index}.py').write_text('fixture')
        large = self.delegate(['stockflow/**'], ['package'], recovery=False)
        self.assertEqual(large['permissionDecision'], 'deny', large)
        for index in range(2):
            result = self.delegate(['new_package/**'], [f'piece{index}'], recovery=False)
            self.assertEqual(result['permissionDecision'], 'allow', result)
            self.hook('SubagentStart', agent_type='algorithm-agent', agent_id=f'normal{index}')
            stopped = self.hook('SubagentStop', agent_type='algorithm-agent', agent_id=f'normal{index}',
                                last_assistant_message='PASS\nSlice succeeded.\nMEMORY: NONE')
            self.assertIn('incomplete', stopped['systemMessage'].lower())
        self.assertEqual(self.hook('Stop')['decision'], 'block')

    def test_nine_distinct_failures_pause_and_hint_is_bounded_valid_json(self):
        self.reset_state([], recovery=False)
        for index in range(9):
            output = self.hook('PostToolUseFailure', tool_name='agent', tool_input={},
                               error=f'LOCALAI_AGENT_PARAMETER_ERROR: distinct invalid value {index}')
        context = output['hookSpecificOutput']['additionalContext']
        self.assertTrue(context.startswith('LOCALAI_WORKFLOW_INCOMPLETE:'), context)
        self.assertLess(len(context),4096)
        json.loads(context.split('AUTHORITATIVE_GROWTH_RECOVERY_STATE=',1)[1])
        self.assertEqual(self.state()['delegation_failure_total'], 9)
        self.reset_state([], recovery=True, objectives=['long_' + 'x' * 1000 + str(i) for i in range(20)])
        output = self.hook('UserPromptSubmit', prompt='')
        context = output['hookSpecificOutput']['additionalContext']
        self.assertLess(len(context), 4096)
        state = json.loads(context.split('AUTHORITATIVE_GROWTH_RECOVERY_STATE=',1)[1])
        self.assertTrue(state['details_omitted'])
        self.assertEqual(state['anchor_count'], 20)
        self.assertNotIn('example', state)

    def test_finished_session_cleanup_and_stale_child_resume(self):
        self.reset_state(['stockflow/**'])
        self.hook('SubagentStart', agent_type='algorithm-agent', agent_id='stale-child')
        self.hook('SessionEnd')
        self.assertIn('AUTHORITATIVE_GROWTH_RECOVERY_STATE=', json.dumps(self.hook('SessionStart')))
        # Only a genuinely successful terminal disposition permits deletion.
        self.python("import workflow_state as w; s=w.get_active_state('growth-session'); s.closure_outcome='success'; w.mark_turn_closed(s)")
        self.hook('SessionEnd')
        self.assertEqual(json.loads(self.python("import workflow_state as w,json; print(json.dumps(w.get_active_state('growth-session')))" ).stdout), None)

    def test_foreign_and_child_callbacks_cannot_mutate_or_disclose_root_state(self):
        self.reset_state(['stockflow/**'])
        before = self.state()
        other = self.base / 'other project'
        other.mkdir()
        for event, values in (
            ('UserPromptSubmit', {'cwd':str(other),'prompt':'other','submitted_prompt':'other'}),
            ('PostToolUseFailure', {'cwd':str(other),'tool_name':'agent','tool_input':{},'error':'LOCALAI_AGENT_PARAMETER_ERROR: invalid'}),
            ('PostToolUseFailure', {'source_type':'subagent','tool_name':'agent','tool_input':{},'error':'LOCALAI_AGENT_PARAMETER_ERROR: invalid'}),
            ('PostToolUseFailure', {'agent_id':'child','tool_name':'agent','tool_input':{},'error':'LOCALAI_AGENT_PARAMETER_ERROR: invalid'}),
        ):
            output = self.hook(event, **values)
            self.assertNotIn('AUTHORITATIVE_GROWTH_RECOVERY_STATE=', json.dumps(output))
            self.assertEqual(self.state(), before)
        self.hook('SubagentStart', agent_type='algorithm-agent', agent_id='child')
        self.hook('SessionEnd', agent_id='child', agent_type='algorithm-agent')
        self.hook('SessionEnd', source_type='subagent')
        self.hook('SessionEnd', agent_type='prompt-agent',source_type='subagent')
        self.assertNotIn('AUTHORITATIVE_GROWTH_RECOVERY_STATE=',json.dumps(self.hook('SessionStart',source_type='subagent')))
        self.read('stockflow/core.py')
        self.assertFalse(self.state()['growth_recovery_reread_files'])
        self.hook('SessionStart', source='resume')
        self.read('stockflow/core.py',source_type='subagent')
        self.assertFalse(self.state()['growth_recovery_reread_files'])
        self.read('stockflow/core.py')
        self.assertEqual(len(self.state()['growth_recovery_reread_files']), 1)

    def test_prompt_only_has_no_false_incomplete_hint_and_missing_evidence_is_separate(self):
        self.python("import workflow_state as w; s=w.get_active_state('growth-session'); s.algorithm_selected=False; s.test_selected=False; w.save_state(s)")
        self.assertNotIn('LOCALAI_ROOT_CONTINUATION:', json.dumps(self.hook('UserPromptSubmit', prompt='')))
        self.reset_state(['stockflow/**','README.md'])
        self.read('README.md', failure=True)
        output = self.hook('UserPromptSubmit', prompt='')
        hint = json.loads(output['hookSpecificOutput']['additionalContext'].split('AUTHORITATIVE_GROWTH_RECOVERY_STATE=',1)[1])
        self.assertEqual(hint['verified_absent_files'], [str(self.project / 'README.md').replace('\\','/').lower()])
        self.assertEqual(len(hint['missing_reads']), 2)
        self.assertFalse(hint['last_successful_slice'])
        self.assertIn('not ready',hint['example_status'])

    def test_oversized_delta_cannot_commit_otherwise_valid_recovery_plan(self):
        self.reset_state(list(self.paths))
        for path in self.paths: self.read(path)
        before = self.state()
        prompt = ('<ALGORITHM_SCOPE>' + json.dumps({'files':['stockflow/core.py'],'objectives':['tests::final']})
                  + '</ALGORITHM_SCOPE><GROWTH_RECOVERY>'
                  + json.dumps({'completed':['model'],'residual':['tests'],'final_slice':True})
                  + '</GROWTH_RECOVERY>' + 'x' * 4000)
        result = self.hook('PreToolUse',tool_name='agent',tool_input={
            'subagent_type':'algorithm-agent','run_in_background':False,'prompt':prompt})
        self.assertEqual(result['hookSpecificOutput']['permissionDecision'],'deny',result)
        self.assertEqual(recovery.GrowthRecoveryTests.without_repair_metadata(self.state()),
                         recovery.GrowthRecoveryTests.without_repair_metadata(before))

    def test_explicit_session_delete_targets_only_owned_deleted_session(self):
        target = '22b6a510-cd5b-4b38-aec2-5446c12a1a6e'
        self.python(f"""
import workflow_state as w, project_identity as p
s=w.create_state({target!r},'deleted-turn',p.identify_project().project_id,overwrite=True)
w.set_active_root_turn(s.session_id,s.turn_id)
w.set_algorithm_scope(s,files=['stockflow/**'],objectives=['package'])
w.mark_growth_recovery_required(s)
""")
        root_before = self.state()
        for values in ({'source_type':'subagent'}, {'agent_id':'child'}, {'deleted_session_id':'../unsafe'},
                       {'cwd':str(self.base)}):
            callback = dict(deleted_session_id=target)
            callback.update(values)
            self.hook('SessionDelete',**callback)
            exists = self.python(f"import workflow_state as w; print(w.get_active_state({target!r}) is not None)").stdout.strip()
            self.assertEqual(exists,'True')
        deleted = self.hook('SessionDelete',deleted_session_id=target)
        self.assertTrue(deleted['continue'])
        exists = self.python(f"import workflow_state as w; print(w.get_session_state_root({target!r}).exists())").stdout.strip()
        self.assertEqual(exists,'False')
        self.assertEqual(self.state(),root_before)
        # Repeated/missing target callbacks cannot delete the caller workflow.
        self.hook('SessionDelete',deleted_session_id=target)
        self.hook('SessionDelete')
        self.assertEqual(self.state(),root_before)

    def test_installed_settings_route_agent_failures_and_session_deletion(self):
        import shutil
        config = self.clone / '.localai/config/local.ps1'
        config.parent.mkdir(parents=True)
        shutil.copy2(self.clone / 'config/local.example.ps1',config)
        outside = lambda: {str(path):path.read_bytes() if path.is_file() else None
                           for root in (self.user / '.qwen',self.old,self.project) for path in root.rglob('*')}
        before = outside()
        self.powershell(f"function powershell.exe {{ $global:LASTEXITCODE=0 }}; & {fixtures.ps_quote(self.clone / 'scripts/install_orchestrator.ps1')}")
        settings = json.loads((self.clone / '.localai/qwen/settings.json').read_text())
        for event,matcher in [('PreToolUse','^(?!agent$).*'),('PostToolUseFailure','^agent$'),('PostToolUseFailure','read_file'),('SessionDelete','*')]:
            hooks=[hook for group in settings['hooks'][event] if group['matcher']==matcher for hook in group['hooks']
                   if hook['name']=='qwen-orchestration-dispatcher']
            self.assertEqual(len(hooks),1,(event,matcher,hooks))
            self.assertIn(str(self.clone / 'orchestration/hook_dispatcher.py'),hooks[0]['command'])
            self.assertNotIn('<CLONE_ROOT>',hooks[0]['command'])
        self.assertEqual(outside(),before)

    def test_stop_stagnation_is_not_an_agent_parameter_repair(self):
        self.reset_state(list(self.paths))
        self.hook('Stop')
        self.hook('Stop')
        self.assertEqual(self.state()['delegation_failure_total'],0)
        before=self.state()['progress_epoch']
        self.read(self.paths[0])
        self.assertGreater(self.state()['progress_epoch'],before)
        self.hook('Stop')
        self.assertEqual(self.state()['stop_stagnation_count'],1)
        self.read(self.paths[0])
        self.hook('Stop')
        self.assertEqual(self.state()['stop_stagnation_count'],2)

    def test_consumed_receipt_cannot_complete_a_later_registered_scope(self):
        self.reset_state(['stockflow/core.py'],recovery=False)
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='first')
        self.hook('SubagentStop',agent_type='algorithm-agent',agent_id='first',terminate_reason='GOAL',last_assistant_message='PASS\nFirst slice complete.\nMEMORY: NONE')
        self.delegate(['stockflow/util.py'],['remaining'],recovery=False)
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='second')
        before=self.state()
        self.hook('SubagentStop',agent_type='algorithm-agent',agent_id='first',terminate_reason='GOAL',last_assistant_message='PASS\nFirst slice complete.\nMEMORY: NONE')
        self.assertFalse(self.state()['algorithm_completed'])
        self.assertEqual(self.state(),before)

    def test_error_after_write_and_invalid_receipt_never_complete(self):
        for mode,receipt in [('ERROR','PASS\nMEMORY: NONE'),('GOAL','FAIL\nUnable to finish.\nMEMORY: NONE'),('GOAL','MEMORY: NONE')]:
            with self.subTest(mode=mode,receipt=receipt):
                self.reset_state(['stockflow/core.py'],recovery=False)
                self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='interrupted')
                (self.project / 'stockflow/core.py').write_text('partial writes')
                self.hook('SubagentStop',agent_type='algorithm-agent',agent_id='interrupted',terminate_reason=mode,last_assistant_message=receipt,stop_hook_active=True)
                self.assertFalse(self.state()['algorithm_completed'])
                self.assertTrue(self.state()['growth_recovery_guard_active'])
                self.assertTrue(self.state()['partial_side_effects_possible'])
                self.hook('SessionEnd')
                self.assertTrue(self.state()['growth_recovery_guard_active'])

    def test_corrupt_referenced_state_cannot_become_prompt_only(self):
        self.python("import workflow_state as w; w.get_state_path('growth-session','growth-turn').write_text('{bad json')")
        response=self.hook('Stop')
        self.assertEqual(response['decision'],'block',response)
        self.assertTrue(response['systemMessage'].startswith('LOCALAI_WORKFLOW_INCOMPLETE:'))
        text=self.python("import workflow_state as w; print(w.get_state_path('growth-session','growth-turn').read_text())").stdout
        self.assertIn('{bad json',text)

    def test_pending_admission_is_immutable_and_receipts_match_api_call(self):
        self.reset_state(['stockflow/core.py'],recovery=False)
        args={'subagent_type':'algorithm-agent','run_in_background':False,'prompt':'<ALGORITHM_SCOPE>'+json.dumps({'files':['stockflow/core.py'],'objectives':['one']})+'</ALGORITHM_SCOPE>Implement one bounded slice.'}
        admitted=self.hook('PreToolUse',tool_name='agent',tool_call_id='api-one',tool_use_id='synthetic-different',tool_input=args)
        self.assertEqual(admitted['hookSpecificOutput']['permissionDecision'],'allow',admitted)
        before=self.state()
        self.hook('PreToolUse',tool_name='agent',tool_call_id='api-one',tool_input=args)
        self.assertEqual(self.state(),before)
        other=dict(args,prompt=args['prompt'].replace('one','two'))
        denied=self.hook('PreToolUse',tool_name='agent',tool_call_id='api-two',tool_input=other)
        self.assertEqual(denied['hookSpecificOutput']['permissionDecision'],'deny')
        self.assertEqual(self.state(),before)
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='reused',parent_tool_call_id='synthetic-different')
        self.assertFalse(self.state()['active_agents'])
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='reused',parent_tool_call_id='api-one')
        active=self.state()
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='reused',parent_tool_call_id='api-one')
        self.assertEqual(self.state(),active)
        denied=self.hook('PreToolUse',tool_name='agent',tool_call_id='api-two',tool_input=other)
        self.assertEqual(denied['hookSpecificOutput']['permissionDecision'],'deny')
        receipt=dict(agent_type='algorithm-agent',agent_id='reused',parent_tool_call_id='api-one',terminate_reason='GOAL',last_assistant_message='PASS\nBounded slice implemented and checked.\nMEMORY: NONE')
        self.hook('SubagentStop',**receipt)
        self.hook('PreToolUse',tool_name='agent',tool_call_id='api-two',tool_input=other)
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='reused',parent_tool_call_id='api-two')
        before=self.state()
        self.hook('SubagentStop',**receipt)
        self.assertEqual(self.state(),before)
        self.hook('SubagentStop',**dict(receipt,parent_tool_call_id='api-two'))
        self.assertEqual(len(self.state()['processed_stops']),2)

    def test_missing_receipt_and_late_test_status_cannot_complete(self):
        self.reset_state(['stockflow/core.py'],recovery=False)
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='missing')
        self.hook('SubagentStop',agent_type='algorithm-agent',agent_id='missing',stop_hook_active=False)
        self.assertFalse(self.state()['algorithm_completed'])
        self.hook('SubagentStop',agent_type='algorithm-agent',agent_id='missing',stop_hook_active=True)
        self.assertTrue(self.state()['growth_recovery_required'])
        self.assertEqual(self.state()['audit_events'][-1]['outcome'],'INVALID_RECEIPT')
        self.reset_state([],recovery=False)
        self.python("import workflow_state as w; s=w.get_active_state('growth-session'); s.algorithm_selected=False; w.save_state(s)")
        self.hook('SubagentStart',agent_type='test-agent',agent_id='test')
        self.hook('SubagentStop',agent_type='test-agent',agent_id='test',stop_hook_active=True,last_assistant_message='Note before status\nPASS\nSynthetic checks completed.\nMEMORY: NONE')
        self.assertFalse(self.state()['final_test_completed'])
        self.hook('SessionEnd')
        self.assertEqual(self.state()['verification_status'],'pending')

    def test_tool_budget_and_creation_breach_latch_until_bound_stop(self):
        self.reset_state([],recovery=False)
        self.assertEqual(self.delegate(['new_package/**'],['create'],recovery=False)['permissionDecision'],'allow')
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='creator')
        child=dict(agent_id='creator',agent_type='algorithm-agent',source_type='subagent')
        directory=self.project/'new_package';directory.mkdir()
        (directory/'core.py').write_text('actual partial state')
        denied=self.hook('PreToolUse',tool_name='run_shell_command',tool_input={'command':'opaque bulk creation'},**child)
        self.assertEqual(denied['hookSpecificOutput']['permissionDecision'],'deny')
        self.assertEqual(self.state()['growth_recovery_generation'],0)
        self.hook('SubagentStop',agent_type='algorithm-agent',agent_id='creator',last_assistant_message='PASS\nLate claim cannot erase interruption.\nMEMORY: NONE')
        self.assertEqual(self.state()['growth_recovery_generation'],1)
        self.assertTrue(self.state()['growth_recovery_required'])
        self.read('new_package/core.py')
        smaller=self.delegate(['new_package/core.py'],['create::repair'],completed=[],residual=['create'])
        self.assertEqual(smaller['permissionDecision'],'allow',smaller)
        self.reset_state(['stockflow/core.py'],recovery=False)
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='tools')
        child=dict(agent_id='tools',agent_type='algorithm-agent',source_type='subagent')
        for index in range(33):
            result=self.hook('PreToolUse',tool_name='read_file',tool_call_id='tool-'+str(index),tool_input={'file_path':str(self.project/'stockflow/core.py')},**child)
        self.assertEqual(result['hookSpecificOutput']['permissionDecision'],'deny')
        self.assertEqual(len(self.state()['active_agents']['tools']['tools']),32)

    def test_discovery_is_read_only_and_generated_files_are_counted(self):
        self.reset_state([],recovery=False)
        self.delegate(['<discover>'],['inspect'],recovery=False)
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='discover')
        self.hook('SubagentStop',agent_type='algorithm-agent',agent_id='discover',last_assistant_message='PASS\nConcrete refinement is ready.\nMEMORY: NONE')
        self.assertTrue(self.state()['scope_requires_refinement'])
        denied=self.hook('PreToolUse',tool_name='agent',tool_input={'subagent_type':'test-agent','prompt':'Test now','run_in_background':False})
        self.assertEqual(denied['hookSpecificOutput']['permissionDecision'],'deny')
        self.assertIn('concrete implementation/refinement',denied['hookSpecificOutput']['permissionDecisionReason'])
        self.reset_state([],recovery=False)
        self.delegate(['generated/**'],['create'],recovery=False)
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='generator')
        directory=self.project/'generated';directory.mkdir()
        for index in range(17): (directory/(str(index)+'.pyc')).write_bytes(b'\0binary')
        self.hook('SubagentStop',agent_type='algorithm-agent',agent_id='generator',last_assistant_message='PASS\nBulk mutation claimed done.\nMEMORY: NONE')
        self.assertFalse(self.state()['algorithm_completed'])
        self.assertEqual(self.state()['audit_events'][-1]['outcome'],'SCOPE_FILE_LIMIT')

    def test_valid_json_routing_corruption_is_preserved_and_blocked(self):
        for broken in ({'active_root_turn_id':[],'agent_root_turns':{}}, {'agent_root_turns':{}}, {'active_root_turn_id':'growth-turn'}):
            self.reset_state(['stockflow/**'])
            self.python(f"import workflow_state as w,json; w._routing_state_path('growth-session').write_text(json.dumps(dict(session_id='growth-session',**{broken!r})))")
            result=self.hook('Stop')
            self.assertEqual(result['decision'],'block',result)
            self.assertTrue(result['systemMessage'].startswith('LOCALAI_WORKFLOW_INCOMPLETE:'))

    def test_short_partition_and_large_index_carrier_are_actionable(self):
        files=[]
        for index in range(14):
            path=self.project/'stockflow'/('item'+str(index)+'.py');path.write_text('fixture')
            files.append(str(path))
        self.reset_state(files)
        hint=json.loads(self.hook('UserPromptSubmit',prompt='')['hookSpecificOutput']['additionalContext'].split('AUTHORITATIVE_GROWTH_RECOVERY_STATE=',1)[1])
        self.assertEqual(hint['residual_objectives'],['model','tests'])
        self.assertIn('example',hint)
        self.assertEqual(hint['missing_read_count'],14)
        self.reset_state(['stockflow/core.py'],objectives=['legacy_'+str(i)+'x'*1000 for i in range(20)])
        self.read('stockflow/core.py')
        state=self.state()
        hint=json.loads(self.hook('UserPromptSubmit',prompt='')['hookSpecificOutput']['additionalContext'].split('AUTHORITATIVE_GROWTH_RECOVERY_STATE=',1)[1])
        carrier={'state_ref':hint['state_ref'],'completed_indices':[],'residual_indices':list(range(20)),'objective_refs':[{'index':0,'child':'check'}],'final_slice':False}
        for change in ({'state_ref':'stale'},{'completed_indices':[True]},{'residual_indices':[0,0]},{'objective_refs':[{'index':20,'child':'check'}]}):
            prompt='<ALGORITHM_SCOPE>'+json.dumps({'files':['stockflow/core.py']})+'</ALGORITHM_SCOPE><GROWTH_RECOVERY>'+json.dumps(dict(carrier,**change))+'</GROWTH_RECOVERY>Check actual state.'
            response=self.hook('PreToolUse',tool_name='agent',tool_input={'subagent_type':'algorithm-agent','run_in_background':False,'prompt':prompt})
            self.assertEqual(response['hookSpecificOutput']['permissionDecision'],'deny')
        self.hook('UserPromptSubmit',prompt='Resume',submitted_prompt='Resume')
        prompt='<ALGORITHM_SCOPE>'+json.dumps({'files':['stockflow/core.py']})+'</ALGORITHM_SCOPE><GROWTH_RECOVERY>'+json.dumps(carrier)+'</GROWTH_RECOVERY>Check actual state.'
        response=self.hook('PreToolUse',tool_name='agent',tool_input={'subagent_type':'algorithm-agent','run_in_background':False,'prompt':prompt})
        self.assertEqual(response['hookSpecificOutput']['permissionDecision'],'allow',response)
        self.assertEqual(self.state()['growth_recovery_anchor_objectives'],state['growth_recovery_anchor_objectives'])

    def test_parallel_admission_tools_and_duplicate_receipts_are_serialized(self):
        from concurrent.futures import ThreadPoolExecutor
        self.reset_state(['stockflow/core.py'],recovery=False)
        def admit(index):
            args={'subagent_type':'algorithm-agent','run_in_background':False,'prompt':'<ALGORITHM_SCOPE>'+json.dumps({'files':['stockflow/core.py'],'objectives':['piece'+str(index)]})+'</ALGORITHM_SCOPE>Implement the bounded fixture.'}
            return self.hook('PreToolUse',tool_name='agent',tool_call_id='parallel-'+str(index),tool_input=args)
        with ThreadPoolExecutor(max_workers=2) as pool: admitted=list(pool.map(admit,range(2)))
        self.assertEqual(sorted(x['hookSpecificOutput']['permissionDecision'] for x in admitted),['allow','deny'])
        parent=self.state()['pending_admission']['call_id']
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='parallel-child',parent_tool_call_id=parent)
        def tool(index):
            return self.hook('PreToolUse',tool_name='read_file',tool_call_id='read-'+str(index),agent_id='parallel-child',agent_type='algorithm-agent',tool_input={'file_path':str(self.project/'stockflow/core.py')})
        with ThreadPoolExecutor(max_workers=8) as pool: tools=list(pool.map(tool,range(8)))
        self.assertTrue(all(x['hookSpecificOutput']['permissionDecision']=='allow' for x in tools))
        self.assertEqual(len(self.state()['active_agents']['parallel-child']['tools']),8)
        before=self.state()['progress_epoch']
        def stop(_):
            return self.hook('SubagentStop',agent_type='algorithm-agent',agent_id='parallel-child',parent_tool_call_id=parent,last_assistant_message='PASS\nEight admitted reads completed.\nMEMORY: NONE')
        with ThreadPoolExecutor(max_workers=2) as pool: list(pool.map(stop,range(2)))
        self.assertEqual(self.state()['progress_epoch'],before+1)
        self.assertEqual(len(self.state()['audit_events']),1)

    def test_test_interruption_survives_end_resume_and_truthful_retry(self):
        for mode in ('GROWTH_LIMIT','ERROR'):
            self.reset_state(['stockflow/core.py'],recovery=False)
            self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='implementation')
            self.hook('SubagentStop',agent_type='algorithm-agent',agent_id='implementation',last_assistant_message='PASS\nImplementation and bounded smoke check complete.\nMEMORY: NONE')
            self.hook('SubagentStart',agent_type='test-agent',agent_id='interrupted-test')
            self.hook('SubagentStop',agent_type='test-agent',agent_id='interrupted-test',terminate_reason=mode)
            self.assertTrue(self.state()['algorithm_completed'])
            self.assertFalse(self.state()['final_test_completed'])
            self.assertEqual(self.hook('Stop')['decision'],'block')
            self.hook('SessionEnd')
            self.hook('SessionStart',source='resume')
            self.hook('UserPromptSubmit',prompt='Resume verification',submitted_prompt='Resume verification')
            self.hook('SubagentStart',agent_type='test-agent',agent_id='retry-test')
            self.hook('SubagentStop',agent_type='test-agent',agent_id='retry-test',last_assistant_message='PASS\nFresh independent fixture checks completed.\nMEMORY: NONE')
            self.assertTrue(self.hook('Stop')['continue'])
            self.assertEqual(self.state()['closure_outcome'],'success')
            self.assertFalse(self.state()['partial_side_effects_possible'])
            self.hook('SessionEnd')
            self.assertEqual(self.python("import workflow_state as w; print(w.get_active_state('growth-session') is None)").stdout.strip(),'True')

    def test_atomic_receipt_fault_keeps_old_or_committed_snapshot(self):
        self.reset_state(['stockflow/core.py'],recovery=False)
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='fault-child')
        for after_replace in (False,True):
            result=self.python(f"""import workflow_state as w,json
s=w.get_active_state('growth-session')
original=w.os.replace
def failed_replace(source,target):
    if {after_replace!r}: original(source,target)
    raise OSError('synthetic replace fault')
w.os.replace=failed_replace
try: w.commit_specialist_stop(s,'fault-child','algorithm_agent','PASS')
except OSError: pass
finally: w.os.replace=original
saved=w.get_active_state('growth-session')
print(json.dumps(dict(completed=saved.algorithm_completed,active=bool(saved.active_agents),consumed=len(saved.processed_stops),epoch=saved.progress_epoch)))
""")
            snapshot=json.loads(result.stdout)
            self.assertEqual(snapshot['completed'],after_replace)
            self.assertEqual(snapshot['active'],not after_replace)
            self.assertEqual(snapshot['consumed'],int(after_replace))
            self.assertEqual(snapshot['epoch'],int(after_replace))
        self.assertEqual(self.python("import workflow_state as w; print(list(w.get_session_state_root('growth-session').glob('*.tmp')))").stdout.strip(),'[]')

    def test_valid_test_failure_records_memory_once_and_preserves_fix_limit(self):
        self.reset_state(['stockflow/core.py'],recovery=False)
        for index in range(3):
            self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='fix-'+str(index))
            self.hook('SubagentStop',agent_type='algorithm-agent',agent_id='fix-'+str(index),last_assistant_message='PASS\nBounded correction completed.\nMEMORY: NONE')
            child='verification-'+str(index)
            self.hook('SubagentStart',agent_type='test-agent',agent_id=child)
            values=dict(agent_type='test-agent',agent_id=child,last_assistant_message='FAIL\nSynthetic assertion remains incorrect.\nMEMORY: NONE')
            self.hook('SubagentStop',**values)
            before=self.python("import project_identity as p,memory_store as m; print(m.read_misunderstandings(p.identify_project()))").stdout
            self.assertIn('equivalent occurrence count='+str(index+1),before)
            self.assertFalse(self.state()['misunderstandings_read'])
            self.hook('SubagentStop',**values)
            self.assertEqual(self.python("import project_identity as p,memory_store as m; print(m.read_misunderstandings(p.identify_project()))").stdout,before)
            stopped=self.hook('Stop')
            self.assertEqual(stopped['decision'],'block')
            self.assertTrue(self.state()['misunderstandings_read'])
        self.assertIn('materially different strategy',before)
        self.assertEqual(max(self.state()['failure_fingerprints'].values()),3)

    def test_closed_predecessor_audit_and_blocked_implementation_resume(self):
        self.reset_state([],recovery=False)
        self.python("import workflow_state as w; s=w.get_active_state('growth-session'); s.algorithm_selected=False; w.save_state(s)")
        self.hook('SubagentStart',agent_type='test-agent',agent_id='audit')
        self.hook('SubagentStop',agent_type='test-agent',agent_id='audit',last_assistant_message='FAIL\nSynthetic audit found a real fixture failure.\nMEMORY: NONE')
        self.hook('Stop')
        self.hook('UserPromptSubmit',prompt='Next genuine audit',submitted_prompt='Next genuine audit',turn_id='next-turn')
        self.assertEqual(self.state()['turn_id'],'next-turn')
        before=self.python("import workflow_state as w,json; print(json.dumps(json.loads((w.STATE_ROOT/'_audit'/'growth-session'/'growth-turn.json').read_text())))").stdout
        self.assertEqual(json.loads(before)['outcome'],'verification_fail')
        self.assertIn('real fixture failure',before)
        self.hook('Stop');self.hook('SessionEnd')
        self.assertEqual(self.python("import workflow_state as w; print((w.STATE_ROOT/'_audit'/'growth-session'/'growth-turn.json').exists())").stdout.strip(),'True')
        self.reset_state(['stockflow/core.py'],recovery=False)
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='implementation')
        self.hook('SubagentStop',agent_type='algorithm-agent',agent_id='implementation',last_assistant_message='PASS\nBounded implementation checks completed.\nMEMORY: NONE')
        self.hook('SubagentStart',agent_type='test-agent',agent_id='blocked-test')
        self.hook('SubagentStop',agent_type='test-agent',agent_id='blocked-test',last_assistant_message='BLOCKED\nIndependent fixture dependency unavailable.\nMEMORY: NONE')
        self.assertIn('unavailable',self.state()['last_failure_summary'])
        self.hook('Stop');prior=self.state()
        self.hook('UserPromptSubmit',prompt='Dependency available, retry verification',submitted_prompt='Dependency available, retry verification',turn_id='new-observation')
        resumed=self.state()
        self.assertEqual(resumed['turn_id'],prior['turn_id'])
        self.assertEqual(resumed['algorithm_scope_objectives'],prior['algorithm_scope_objectives'])
        self.assertTrue(resumed['algorithm_completed'])
        self.assertFalse(resumed['final_test_completed'])
        self.assertEqual(resumed['verification_status'],'pending')
        self.assertIn('unavailable',json.dumps(resumed['audit_events']))
        self.hook('SubagentStart',agent_type='test-agent',agent_id='fresh-test')
        self.hook('SubagentStop',agent_type='test-agent',agent_id='fresh-test',last_assistant_message='PASS\nFresh independent verification completed.\nMEMORY: NONE')
        self.assertTrue(self.hook('Stop')['continue'])

    def test_redirected_transition_lock_denies_before_any_state_access(self):
        import os
        self.reset_state(['stockflow/**'])
        before=self.state()
        outside={str(p):p.read_bytes() for p in self.old.rglob('*') if p.is_file()}
        lockroot=self.clone/'.localai/orchestration/state/_locks'
        lockroot.parent.mkdir(parents=True,exist_ok=True)
        self.powershell(f"New-Item -ItemType Junction -Path {fixtures.ps_quote(lockroot)} -Target {fixtures.ps_quote(self.old)} | Out-Null")
        try:
            pre=self.hook('PreToolUse',tool_name='read_file',tool_call_id='safe-read',tool_input={'file_path':str(self.project/'stockflow/core.py')})
            self.assertEqual(pre['hookSpecificOutput']['permissionDecision'],'deny',pre)
            self.assertTrue(pre['hookSpecificOutput']['permissionDecisionReason'].startswith('LOCALAI_WORKFLOW_INCOMPLETE:'))
            for event in ('PostToolUse','Stop'):
                output=self.hook(event,tool_name='read_file',tool_call_id='safe-read',tool_input={'file_path':str(self.project/'stockflow/core.py')})
                self.assertEqual(output['decision'],'block',output)
                self.assertFalse(output['continue'])
            self.assertEqual(outside,{str(p):p.read_bytes() for p in self.old.rglob('*') if p.is_file()})
        finally:
            os.rmdir(lockroot)
        self.assertEqual(self.state(),before)

    def test_malformed_owned_mutation_inputs_are_denied_without_credit(self):
        for name in ('write_file','edit'):
            inputs=[{},*({'tool_input':value} for value in (None,[],"bad",{}, {'file_path':[]}, {'file_path':str(self.project/'stockflow/core.py')}))]
            for kwargs in inputs:
                with self.subTest(name=name,input=kwargs):
                    self.reset_state(['stockflow/core.py'],recovery=False)
                    self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='input-child')
                    before=(self.project/'stockflow/core.py').read_bytes()
                    epoch=self.state()['progress_epoch']
                    output=self.hook('PreToolUse',tool_name=name,tool_call_id='malformed-call',
                                     agent_id='input-child',agent_type='algorithm-agent',**kwargs)
                    self.assertEqual(output.get('hookSpecificOutput',{}).get('permissionDecision'),'deny',output)
                    self.assertFalse(self.state()['algorithm_completed'])
                    self.assertEqual(self.state()['progress_epoch'],epoch)
                    self.assertEqual((self.project/'stockflow/core.py').read_bytes(),before)

    def test_pre_exceptions_and_logger_failure_never_authorize_execution(self):
        self.reset_state(['stockflow/core.py'],recovery=False)
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='fault-input')
        before=self.state()
        payload=dict(hook_event_name='PreToolUse',session_id='growth-session',cwd=str(self.project),
                     agent_id='fault-input',agent_type='algorithm-agent',tool_name='write_file',tool_call_id='fault-call',
                     tool_input={'file_path':str(self.project/'stockflow/core.py'),'content':'synthetic'})
        for target,kind in (('_slice_tool_event','AttributeError'),('_project_identity','TypeError'),('_localai_v514_project_path','RuntimeError')):
            for logging_failure in (False,True):
                with self.subTest(target=target,kind=kind,logging_failure=logging_failure):
                    result=self.python(f"""import hook_dispatcher as h,json
h._read_hook_input=lambda:json.loads({json.dumps(payload)!r})
def fail(*args,**kwargs): raise {kind}('synthetic trusted-boundary failure')
h.{target}=fail
if {logging_failure!r}: h._log_error=fail
h.main()
""")
                    output=json.loads(result.stdout)
                    self.assertEqual(output.get('hookSpecificOutput',{}).get('permissionDecision'),'deny',output)
                    self.assertFalse(self.state()['algorithm_completed'])
        result=self.python(f"""import hook_dispatcher as h,json
from pathlib import Path
h._read_hook_input=lambda:json.loads({json.dumps(payload)!r})
def fail(*args,**kwargs): raise AttributeError('synthetic admission failure')
h._slice_tool_event=fail
h.ERROR_LOG_PATH=Path({str(self.old/'forbidden.log')!r})
h.main()
""")
        self.assertEqual(json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'],'deny')
        self.assertFalse((self.old/'forbidden.log').exists())
        self.assertEqual(self.state(),before)

    def test_valid_owned_mutation_and_read_admissions_do_not_complete_slice(self):
        self.reset_state(['stockflow/core.py'],recovery=False)
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='valid-input')
        path=str(self.project/'stockflow/core.py'); before=(self.project/'stockflow/core.py').read_bytes()
        for index,(name,args) in enumerate((('write_file',{'file_path':path,'content':'new synthetic'}),
                                           ('edit',{'file_path':path,'old_string':'fixture','new_string':'revised'}),
                                           ('read_file',{'file_path':path}))):
            output=self.hook('PreToolUse',tool_name=name,tool_call_id='valid-'+str(index),tool_input=args,
                             agent_id='valid-input',agent_type='algorithm-agent')
            self.assertEqual(output['hookSpecificOutput']['permissionDecision'],'allow',output)
        self.assertFalse(self.state()['algorithm_completed'])
        self.assertEqual((self.project/'stockflow/core.py').read_bytes(),before)

    def test_not_started_restores_scope_uncertainty_and_bounds_same_strategy(self):
        self.reset_state(list(self.paths))
        for path in self.paths: self.read(path)
        before=self.state()
        for attempt in range(3):
            accepted=self.delegate(['stockflow/core.py'],['model::verify'],completed=['tests'],residual=['model'])
            self.assertEqual(accepted['permissionDecision'],'allow',accepted)
            admission=self.state()['pending_admission']
            failure=dict(tool_name='agent',tool_call_id=admission['call_id'],tool_use_id='different-synthetic-id',
                         tool_input=admission['tool_input'],execution_status='not_started',error='Synthetic guard denial')
            output=self.hook('PostToolUseFailure',**failure)
            state=self.state()
            self.assertIsNone(state['pending_admission'])
            self.assertEqual(state['processed_stops'][admission['call_id']],'NOT_STARTED')
            for key in ('algorithm_scope_files','algorithm_scope_objectives','growth_recovery_completed_objectives',
                        'growth_recovery_residual_objectives','growth_recovery_required','partial_side_effects_possible'):
                self.assertEqual(state[key],before[key],key)
            self.assertEqual(state['delegation_failure_total'],attempt+1)
            self.hook('PostToolUseFailure',**failure)
            self.assertEqual(self.state(),state)
            late=self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='late-'+str(attempt),parent_tool_call_id=admission['call_id'])
            self.assertFalse(late['continue'])
        self.assertTrue(output['hookSpecificOutput']['additionalContext'].startswith('LOCALAI_WORKFLOW_INCOMPLETE:'))
        self.assertFalse(self.state()['algorithm_completed'])

    def test_ambiguous_failure_blocks_late_start_and_resume_requires_real_recovery(self):
        self.reset_state(['stockflow/core.py'],recovery=False,objectives=['first'])
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='first')
        self.hook('SubagentStop',agent_type='algorithm-agent',agent_id='first',last_assistant_message='PASS\nFirst bounded slice verified.\nMEMORY: NONE')
        self.delegate(['stockflow/util.py'],['second'],recovery=False)
        admission=self.state()['pending_admission']
        failure=dict(tool_name='agent',tool_call_id=admission['call_id'],tool_input=admission['tool_input'],error='Factory failed before observed Start')
        output=self.hook('PostToolUseFailure',**failure)
        state=self.state()
        self.assertTrue(output['hookSpecificOutput']['additionalContext'].startswith('LOCALAI_WORKFLOW_INCOMPLETE:'))
        self.assertIsNotNone(state['pending_admission'])
        self.assertFalse(state['algorithm_completed'])
        self.assertTrue(state['partial_side_effects_possible'])
        self.hook('PostToolUseFailure',**failure);self.assertEqual(self.state(),state)
        late=self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='late',parent_tool_call_id=admission['call_id'])
        self.assertFalse(late['continue'])
        self.hook('SessionEnd');self.hook('SessionStart',source='resume')
        self.hook('UserPromptSubmit',prompt='Continue from evidence',submitted_prompt='Continue from evidence')
        self.assertFalse(self.state()['algorithm_completed'])
        self.assertTrue(self.state()['growth_recovery_required'])
        test=self.hook('PreToolUse',tool_name='agent',tool_input={'subagent_type':'test-agent','prompt':'Verify too early','run_in_background':False})
        self.assertEqual(test['hookSpecificOutput']['permissionDecision'],'deny')
        self.read('stockflow/util.py')
        repaired=self.delegate(['stockflow/util.py'],['second::repair'],completed=[],residual=['second'],final_slice=True)
        self.assertEqual(repaired['permissionDecision'],'allow',repaired)

    def test_prestart_failure_ownership_phase_and_legacy_snapshot_fail_closed(self):
        self.reset_state(['stockflow/core.py'],recovery=False)
        self.delegate(['stockflow/core.py'],['bounded'],recovery=False)
        admission=self.state()['pending_admission'];before=self.state()
        failure=dict(tool_name='agent',tool_call_id=admission['call_id'],tool_input=admission['tool_input'],execution_status='not_started',error='Synthetic guard denial')
        other=self.base/'foreign project';other.mkdir()
        for changes in ({'tool_call_id':'foreign-api'},{'cwd':str(other)},{'source_type':'subagent'},{'agent_id':'foreign-child'}):
            self.hook('PostToolUseFailure',**dict(failure,**changes));self.assertEqual(self.state(),before)
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='active')
        started=self.state();self.hook('PostToolUseFailure',**failure);self.assertEqual(self.state(),started)
        self.hook('SubagentStop',agent_type='algorithm-agent',agent_id='active',terminate_reason='GROWTH_LIMIT')
        ended=self.state();self.hook('PostToolUseFailure',**failure);self.assertEqual(self.state(),ended)
        # An input field is not native phase evidence, and entered failures remain uncertain.
        self.reset_state(['stockflow/core.py'],recovery=False)
        self.delegate(['stockflow/core.py'],['bounded'],recovery=False)
        admission=self.state()['pending_admission'];before=self.state()
        forged=dict(admission['tool_input'],execution_status='not_started')
        self.hook('PostToolUseFailure',tool_name='agent',tool_call_id=admission['call_id'],tool_input=forged,error='Input cannot certify phase')
        self.assertEqual(self.state(),before)
        self.hook('PostToolUseFailure',tool_name='agent',tool_call_id=admission['call_id'],tool_input=admission['tool_input'],
                  execution_status='error',error='Execution entered without a successful Start receipt')
        self.assertIsNotNone(self.state()['pending_admission'])
        self.assertTrue(self.state()['partial_side_effects_possible'])
        # A prior completed slice cannot certify a never-started second implementation scope.
        self.reset_state(['stockflow/core.py'],recovery=False,objectives=['first'])
        self.hook('SubagentStart',agent_type='algorithm-agent',agent_id='first')
        self.hook('SubagentStop',agent_type='algorithm-agent',agent_id='first',last_assistant_message='PASS\nFirst slice verified.\nMEMORY: NONE')
        self.delegate(['stockflow/util.py'],['second'],recovery=False)
        admission=self.state()['pending_admission']
        self.hook('PostToolUseFailure',**dict(failure,tool_call_id=admission['call_id'],tool_input=admission['tool_input']))
        self.hook('UserPromptSubmit',prompt='Retry the new scope',submitted_prompt='Retry the new scope')
        self.assertFalse(self.state()['algorithm_completed'])
        self.assertEqual(self.state()['last_successful_algorithm_objectives'],['first'])
        self.assertEqual(self.hook('PreToolUse',tool_name='agent',tool_input={'subagent_type':'test-agent','run_in_background':False,'prompt':'Premature verification'})['hookSpecificOutput']['permissionDecision'],'deny')
        from concurrent.futures import ThreadPoolExecutor
        self.reset_state(['stockflow/core.py'],recovery=False)
        self.delegate(['stockflow/core.py'],['bounded'],recovery=False)
        admission=self.state()['pending_admission'];epoch=self.state()['progress_epoch']
        events=[('SubagentStart',dict(agent_type='algorithm-agent',agent_id='racing-child',parent_tool_call_id=admission['call_id'])),
                ('PostToolUseFailure',dict(failure,tool_call_id=admission['call_id'],tool_input=admission['tool_input']))]
        with ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(lambda item:self.hook(item[0],**item[1]),events))
        raced=self.state()
        self.assertFalse(raced['algorithm_completed'])
        self.assertEqual(raced['progress_epoch'],epoch)
        self.assertNotEqual(bool(raced['active_agents']),admission['call_id'] in raced['processed_stops'])
        self.reset_state(['stockflow/core.py'],recovery=False)
        self.delegate(['stockflow/core.py'],['bounded'],recovery=False)
        admission=self.state()['pending_admission']
        self.python("import workflow_state as w; s=w.get_active_state('growth-session'); s.pending_admission.pop('prior_state',None); w.save_state(s)")
        self.hook('PostToolUseFailure',**dict(failure,tool_call_id=admission['call_id'],tool_input=admission['tool_input']))
        self.assertIsNotNone(self.state()['pending_admission'])
        self.assertTrue(self.state()['partial_side_effects_possible'])
