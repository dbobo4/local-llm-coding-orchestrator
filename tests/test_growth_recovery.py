"""Growth recovery coverage and read evidence through isolated real hook calls."""

from __future__ import annotations

import json
import os
import subprocess
import sys

import test_local_installation as fixtures


class GrowthRecoveryTests(fixtures.FixtureTest):
    def setUp(self):
        super().setUp()
        self.copy_sources()
        identity = self.clone / 'orchestration' / 'project_identity.py'
        identity.write_text(identity.read_text() + '\n_find_git_root = lambda cwd: None\n')
        self.paths = ('stockflow/core.py', 'stockflow/util.py', 'tests/test_core.py')
        for relative in self.paths:
            path = self.project / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture content\n')
        self.reset_state(['stockflow/**', 'tests/**', 'README.md'])

    def reset_state(self, files, recovery=True, *, objectives=None):
        self.python(f"""
import project_identity as identity, workflow_state as w
p=identity.identify_project()
s=w.create_state('growth-session','growth-turn',p.project_id,overwrite=True)
w.set_active_root_turn(s.session_id,s.turn_id)
w.mark_contract_ready(s)
w.select_implementation_workflow(s,require_test=True)
w.set_algorithm_scope(s,files={files!r},objectives={objectives or ['model','tests']!r})
if {recovery!r}: w.mark_growth_recovery_required(s)
""")

    def state(self):
        return json.loads(self.python("""
import json, workflow_state as w
from dataclasses import asdict
print(json.dumps(asdict(w.get_active_state('growth-session'))))
""").stdout)

    def hook(self, event, **values):
        payload = dict(hook_event_name=event, session_id='growth-session', cwd=str(self.project))
        payload.update(values)
        result = subprocess.run([sys.executable, '-B', str(self.clone / 'orchestration' / 'hook_dispatcher.py')],
                                input=json.dumps(payload), cwd=self.project, env=self.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def read(self, relative, *, failure=False, **values):
        path = str(self.project / relative)
        return self.hook('PostToolUseFailure' if failure else 'PostToolUse',
                         tool_name='read_file', tool_input={'file_path': path},
                         error='File not found: ' + path, is_interrupt=False, **values)

    def delegate(self, files, objectives=None, *, completed=None, residual=None, final_slice=False, recovery=True):
        scope = dict(files=files, objectives=objectives or ['model::slice'])
        prompt = '<ALGORITHM_SCOPE>' + json.dumps(scope) + '</ALGORITHM_SCOPE>\nImplement the residual slice.'
        if recovery:
            plan = dict(completed=completed or [], residual=residual if residual is not None else ['model','tests'], final_slice=final_slice)
            prompt += '\n<GROWTH_RECOVERY>' + json.dumps(plan) + '</GROWTH_RECOVERY>'
        return self.hook('PreToolUse', tool_name='agent', tool_input={
            'subagent_type':'algorithm-agent', 'run_in_background':False, 'prompt':prompt,
        })['hookSpecificOutput']

    def reread_all(self):
        for path in self.paths:
            self.read(path)
        self.read('README.md', failure=True)

    def prepare_second_orders_growth(self):
        self.paths = tuple('stockflow/' + name for name in
                           ('__init__.py','__main__.py','catalog.py','orders.py','apply.py','report.py','cli.py'))
        for relative in self.paths:
            (self.project / relative).write_text('synthetic order-ledger file\n')
        anchors = ['orders_validation','apply_transactional','report_cmd']
        self.reset_state(list(self.paths), recovery=False, objectives=anchors)
        self.hook('SubagentStart', agent_type='algorithm-agent', agent_id='first-growth')
        self.hook('SubagentStop', agent_type='algorithm-agent', agent_id='first-growth', terminate_reason='GROWTH_LIMIT')
        for path in self.paths:
            self.read(path)
        accepted = self.delegate(list(self.paths), ['apply_transactional::implement'],
                                 completed=['orders_validation','report_cmd'], residual=['apply_transactional'])
        self.assertEqual(accepted['permissionDecision'], 'allow', accepted)
        self.hook('SubagentStart', agent_type='algorithm-agent', agent_id='second-growth')
        self.hook('SubagentStop', agent_type='algorithm-agent', agent_id='second-growth', terminate_reason='GROWTH_LIMIT')
        self.assertEqual(self.state()['growth_recovery_generation'], 2)
        return anchors

    def test_second_growth_keeps_unverified_parent_until_final_smoke_success(self):
        anchors = self.prepare_second_orders_growth()
        for path in self.paths[:-1]:
            self.read(path)
        plan = dict(completed=['orders_validation','report_cmd'], residual=['apply_transactional'], final_slice=True)
        partial = self.delegate(['stockflow/apply.py'], ['apply_transactional::smoke_check'], **plan)
        self.assertEqual(partial['permissionDecision'], 'deny', partial)
        self.assertIn('stockflow/cli.py', partial['permissionDecisionReason'])
        self.read(self.paths[-1])
        before = self.state()
        bad = self.delegate(['stockflow/apply.py'], ['apply_transactional::smoke_check'],
                            completed=anchors, residual=[], final_slice=True)
        self.assertEqual(bad['permissionDecision'], 'deny', bad)
        self.assertIn('empty residual', bad['permissionDecisionReason'].lower())
        self.assertIn('apply_transactional', bad['permissionDecisionReason'])
        self.assertEqual(self.state(), before)
        accepted = self.delegate(['stockflow/apply.py'], ['apply_transactional::smoke_check'], **plan)
        self.assertEqual(accepted['permissionDecision'], 'allow', accepted)
        self.assertTrue(self.state()['growth_recovery_guard_active'])
        blocked_test = self.hook('PreToolUse', tool_name='agent', tool_input={
            'subagent_type':'test-agent','run_in_background':False,'prompt':'Verify the final implementation.',
        })['hookSpecificOutput']
        self.assertEqual(blocked_test['permissionDecision'], 'deny', blocked_test)
        self.assertEqual(self.hook('Stop')['decision'], 'block')
        self.hook('SubagentStart', agent_type='algorithm-agent', agent_id='smoke-child')
        incomplete = self.hook('SubagentStop', agent_type='algorithm-agent', agent_id='smoke-child',
                               last_assistant_message='Smoke check finished without a valid receipt.')
        self.assertEqual(incomplete['decision'], 'block')
        self.assertTrue(self.state()['growth_recovery_guard_active'])
        self.hook('SubagentStop', agent_type='algorithm-agent', agent_id='smoke-child',
                  last_assistant_message='Synthetic implementation smoke check passed.\nMEMORY: NONE')
        self.assertFalse(self.state()['growth_recovery_guard_active'])
        self.assertEqual(self.hook('Stop')['decision'], 'block')
        self.hook('SubagentStart', agent_type='test-agent', agent_id='final-orders-test')
        self.hook('SubagentStop', agent_type='test-agent', agent_id='final-orders-test',
                  last_assistant_message='PASS\nMEMORY: NONE')
        self.assertTrue(self.hook('Stop')['continue'])

    def test_empty_residual_claim_and_another_growth_stop_cannot_close_recovery(self):
        anchors = self.prepare_second_orders_growth()
        for path in self.paths:
            self.read(path)
        before = self.state()
        for final in (False, True):
            denied = self.delegate(['stockflow/apply.py'], ['apply_transactional::smoke_check'],
                                   completed=anchors, residual=[], final_slice=final)
            self.assertEqual(denied['permissionDecision'], 'deny', denied)
            self.assertIn('empty residual', denied['permissionDecisionReason'].lower())
            self.assertEqual(self.state(), before)
        test_start = self.hook('SubagentStart', agent_type='test-agent', agent_id='premature-orders-test')
        self.assertFalse(test_start['continue'])
        self.assertEqual(self.hook('Stop')['decision'], 'block')
        accepted = self.delegate(['stockflow/apply.py'], ['apply_transactional::smoke_check'],
                                 completed=['orders_validation','report_cmd'], residual=['apply_transactional'], final_slice=True)
        self.assertEqual(accepted['permissionDecision'], 'allow', accepted)
        self.hook('SubagentStart', agent_type='algorithm-agent', agent_id='interrupted-smoke')
        self.hook('SubagentStop', agent_type='algorithm-agent', agent_id='interrupted-smoke',
                  terminate_reason='GROWTH_LIMIT', last_assistant_message='No verified final result.\nMEMORY: NONE')
        state = self.state()
        self.assertTrue(state['growth_recovery_guard_active'])
        self.assertTrue(state['growth_recovery_required'])
        self.assertFalse(state['growth_recovery_final_slice'])
        self.assertEqual(state['growth_recovery_completed_objectives'], ['orders_validation','report_cmd'])
        denied = self.delegate(['stockflow/apply.py'], ['apply_transactional::verify_actual_state'],
                               completed=anchors, residual=[], final_slice=True)
        self.assertEqual(denied['permissionDecision'], 'deny', denied)
        self.assertTrue(self.state()['growth_recovery_guard_active'])

    def test_missing_parent_diagnostic_names_exact_residual_mismatch(self):
        anchors = ['orders_validation','apply_transactional','report_cmd']
        self.reset_state(['stockflow/core.py'], objectives=anchors)
        self.read('stockflow/core.py')
        before = self.state()
        denied = self.delegate(['stockflow/core.py'], ['apply_transactional::smoke_check'],
                               completed=['orders_validation','apply_transactional'], residual=['report_cmd'])
        self.assertEqual(denied['permissionDecision'], 'deny', denied)
        self.assertIn('apply_transactional', denied['permissionDecisionReason'])
        self.assertIn('missing from residual', denied['permissionDecisionReason'])
        self.assertEqual(self.state(), before)

    def test_legacy_wildcards_require_every_current_file_and_concrete_absence(self):
        self.read('stockflow/core.py')
        denied = self.delegate(['stockflow/core.py'])
        self.assertEqual(denied['permissionDecision'], 'deny')
        self.assertIn('stockflow/util.py', denied['permissionDecisionReason'].lower())
        self.reread_all()
        accepted = self.delegate(['stockflow/core.py'])
        self.assertEqual(accepted['permissionDecision'], 'allow', accepted)
        state = self.state()
        self.assertEqual(state['growth_recovery_failed_files'], ['stockflow/**','tests/**','README.md'])
        self.assertTrue(state['growth_recovery_guard_active'])
        self.assertFalse(state['growth_recovery_required'])

    def test_unsupported_and_directory_scopes_are_denied_early(self):
        for files in (['stockflow/*.py'], ['stockflow'], ['../outside.py'], ['tests/<discover>']):
            with self.subTest(files=files):
                self.reset_state([], recovery=False)
                result = self.delegate(files, recovery=False)
                self.assertEqual(result['permissionDecision'], 'deny', result)
                self.assertIn('<discover>', result['permissionDecisionReason'])
                self.assertEqual(self.state()['algorithm_scope_files'], [])

    def test_initial_absent_and_empty_subtrees_allow_creation_then_require_coverage(self):
        for name, empty in (('absent', False), ('empty', True)):
            with self.subTest(initial=name):
                package, tests = f'{name}_package', f'{name}_tests'
                if empty:
                    (self.project / package).mkdir()
                    (self.project / tests).mkdir()
                scope = [package + '/**', tests + '/**', 'README.md']
                self.reset_state([], recovery=False)
                accepted = self.delegate(scope, ['model','tests'], recovery=False)
                self.assertEqual(accepted['permissionDecision'], 'allow', accepted)
                self.assertEqual(self.state()['algorithm_scope_files'], [item.lower() for item in scope])
                self.hook('SubagentStart', agent_type='algorithm-agent', agent_id='creation-child')
                for directory in (package, tests):
                    path = self.project / directory / 'one.py'
                    path.parent.mkdir(exist_ok=True)
                    path.write_text('created fixture\n')
                self.hook('SubagentStop', agent_type='algorithm-agent', agent_id='creation-child',
                          terminate_reason='GROWTH_LIMIT', last_assistant_message='Interrupted creation.')
                self.read(package + '/one.py')
                self.read('README.md', failure=True)
                denied = self.delegate([package + '/one.py'])
                self.assertEqual(denied['permissionDecision'], 'deny', denied)
                self.assertIn(tests + '/one.py', denied['permissionDecisionReason'].lower())
                self.read(tests + '/one.py')
                accepted = self.delegate([package + '/one.py'])
                self.assertEqual(accepted['permissionDecision'], 'allow', accepted)

    def test_missing_empty_and_emptied_recovery_subtrees_remain_guarded(self):
        (self.project / 'empty').mkdir()
        emptied = self.project / 'emptied'
        emptied.mkdir()
        removed = emptied / 'removed.py'
        removed.write_text('fixture\n')
        self.reset_state(['emptied/**'])
        removed.unlink()
        for scope in ('missing/**', 'empty/**', 'emptied/**'):
            with self.subTest(scope=scope):
                self.reset_state([scope])
                self.read('stockflow/core.py')
                denied = self.delegate(['stockflow/core.py'])
                self.assertEqual(denied['permissionDecision'], 'deny', denied)
                self.assertIn('complete file coverage', denied['permissionDecisionReason'])
                state = self.state()
                self.assertTrue(state['growth_recovery_required'])
                self.assertEqual(state['growth_recovery_reread_files'], [])

    def test_generated_and_nontext_files_are_not_silently_excluded(self):
        cache = self.project / 'stockflow' / '__pycache__' / 'core.pyc'
        cache.parent.mkdir()
        cache.write_bytes(b'\0\xfffixture')
        binary = self.project / 'stockflow' / 'data.bin'
        binary.write_bytes(b'\0\xfffixture')
        self.reset_state(['stockflow/**'])
        self.read('stockflow/core.py'); self.read('stockflow/util.py')
        for path in ('stockflow/__pycache__/core.pyc', 'stockflow/data.bin'):
            self.read(path, failure=True)
            self.read(path, tool_response={
                'llmContent': 'Cannot display content of binary file: ' + path,
                'returnDisplay': 'Skipped binary file: ' + path,
            })
        self.assertEqual(len(self.state()['growth_recovery_reread_files']), 2)
        denied = self.delegate(['stockflow/core.py'])
        self.assertEqual(denied['permissionDecision'], 'deny', denied)
        self.assertIn('__pycache__/core.pyc', denied['permissionDecisionReason'])
        self.assertIn('stockflow/data.bin', denied['permissionDecisionReason'])
        self.assertTrue(self.state()['growth_recovery_required'])
        readme = self.project / 'README.md'
        content = 'Cannot display content of binary file: sample\nSkipped binary file: sample\n'
        readme.write_text(content)
        self.reset_state(['README.md'])
        self.read('README.md', tool_response={'llmContent': content, 'returnDisplay': ''})
        self.assertEqual(len(self.state()['growth_recovery_reread_files']), 1)

    def test_failure_label_cannot_fabricate_a_reread(self):
        self.reset_state(['stockflow/core.py','README.md'])
        self.read('stockflow/core.py', failure=True)
        self.read('stockflow/**', failure=True)
        self.read('README.md', failure=True)
        self.assertEqual(self.state()['growth_recovery_reread_files'], [str(self.project / 'README.md').replace('\\','/').lower()])
        self.reset_state(['README.md'])
        self.hook('PostToolUseFailure', tool_name='read_file', tool_input={'file_path': str(self.project / 'README.md')},
                  error='Permission denied', is_interrupt=False)
        self.assertEqual(self.state()['growth_recovery_reread_files'], [])
        self.read('README.md', failure=True, agent_id='child-agent')
        self.assertEqual(self.state()['growth_recovery_reread_files'], [])
        self.reset_state(['file_not_found.py'])
        path = str(self.project / 'file_not_found.py')
        self.hook('PostToolUseFailure', tool_name='read_file', tool_input={'file_path': path},
                  error='Permission denied: ' + path, is_interrupt=False)
        self.assertEqual(self.state()['growth_recovery_reread_files'], [])
        self.read('file_not_found.py', failure=True)
        self.assertEqual(len(self.state()['growth_recovery_reread_files']), 1)
        self.reset_state(['<discover>'])
        self.read('README.md', failure=True)
        self.assertEqual(self.state()['growth_recovery_reread_files'], [])
        self.read('stockflow/core.py')
        self.assertEqual(len(self.state()['growth_recovery_reread_files']), 1)

    def test_outside_root_same_basename_never_satisfies_scope(self):
        self.reset_state(['stockflow/core.py'])
        outside = self.old / 'stockflow' / 'core.py'
        outside.parent.mkdir()
        outside.write_text('outside fixture\n')
        self.hook('PostToolUse', tool_name='read_file', tool_input={'file_path': str(outside)})
        self.assertEqual(self.state()['growth_recovery_reread_files'], [])
        denied = self.delegate(['stockflow/core.py'])
        self.assertEqual(denied['permissionDecision'], 'deny')

    def test_child_shaped_reads_need_no_agent_id_to_be_rejected(self):
        self.hook('SubagentStart', agent_type='algorithm-agent', agent_id='algorithm-child')
        # Pinned child tool hooks share the root session and omit agent_id.
        self.read('stockflow/core.py')
        self.read('README.md', failure=True)
        self.assertEqual(self.state()['growth_recovery_reread_files'], [])
        self.hook('SubagentStop', agent_type='algorithm-agent', agent_id='algorithm-child',
                  terminate_reason='GROWTH_LIMIT', last_assistant_message='Interrupted synthetic slice.')
        self.read('stockflow/core.py')
        self.read('README.md', failure=True)
        self.assertEqual(len(self.state()['growth_recovery_reread_files']), 2)

    def test_windows_absolute_paths_and_case_resolve_to_exact_files(self):
        self.reset_state(['stockflow\\CORE.py','README.md'])
        self.hook('PostToolUse', tool_name='read_file', tool_input={'file_path': str(self.project / 'stockflow/core.py').upper()})
        self.read('README.md', failure=True)
        accepted = self.delegate([str(self.project / 'stockflow/core.py')])
        self.assertEqual(accepted['permissionDecision'], 'allow', accepted)

    def test_resolved_full_scope_and_semantic_gate_bypasses_are_denied(self):
        self.reread_all()
        cases = ((list(self.paths)+['README.md'], ['model','tests'], [], ['model','tests'], False, 'same-scope'),
                 (['stockflow/core.py'], ['model::slice'], ['model'], ['model','tests'], False, 'disjoint'),
                 (['stockflow/core.py'], ['model::slice'], [], ['model'], False, 'partition'),
                 (['stockflow/core.py'], ['model::slice'], [], ['model','tests'], True, 'final_slice'))
        for files, objectives, completed, residual, final, reason in cases:
            with self.subTest(reason=reason):
                result = self.delegate(files, objectives, completed=completed, residual=residual, final_slice=final)
                self.assertEqual(result['permissionDecision'], 'deny', result)
                self.assertIn(reason, result['permissionDecisionReason'])
                self.assertTrue(self.state()['growth_recovery_required'])

    def test_redirected_subtree_is_not_enumerated(self):
        target = self.old / 'redirect-target'
        target.mkdir()
        (target / 'hidden.py').write_text('outside fixture\n')
        junction = self.project / 'redirect'
        self.powershell(f'New-Item -ItemType Junction -Path {fixtures.ps_quote(junction)} -Target {fixtures.ps_quote(target)} | Out-Null')
        try:
            self.reset_state([], recovery=False)
            initial = self.delegate(['redirect/**'], recovery=False)
            self.assertEqual(initial['permissionDecision'], 'deny', initial)
            self.assertEqual(self.state()['algorithm_scope_files'], [])
            self.reset_state(['redirect/**'])
            denied = self.delegate(['stockflow/core.py'])
            self.assertEqual(denied['permissionDecision'], 'deny')
            self.assertIn('<discover>', denied['permissionDecisionReason'])
            self.assertTrue(self.state()['growth_recovery_required'])
        finally:
            os.rmdir(junction)

    def test_supported_initial_scope_and_nested_inventory_limit(self):
        nested = self.project / 'stockflow' / 'nested' / 'extra.py'
        nested.parent.mkdir()
        nested.write_text('nested fixture\n')
        self.reset_state([], recovery=False)
        accepted = self.delegate(['stockflow/**'], recovery=False)
        self.assertEqual(accepted['permissionDecision'], 'allow', accepted)
        self.assertEqual(self.state()['algorithm_scope_files'], ['stockflow/**'])
        self.reset_state(['stockflow/**'])
        self.read('stockflow/core.py'); self.read('stockflow/util.py')
        denied = self.delegate(['stockflow/core.py'])
        self.assertIn('nested/extra.py', denied['permissionDecisionReason'].lower())
        bulk = self.project / 'bulk'
        bulk.mkdir()
        for index in range(257):
            (bulk / f'{index}.py').write_text('fixture\n')
        self.reset_state([], recovery=False)
        denied = self.delegate(['bulk/**'], recovery=False)
        self.assertEqual(denied['permissionDecision'], 'deny')
        self.assertIn('256-file', denied['permissionDecisionReason'])
        self.assertEqual(self.state()['algorithm_scope_files'], [])

    def test_alias_retry_and_final_slice_lifecycle_preserve_semantic_guards(self):
        self.reread_all()
        accepted = self.delegate(['stockflow/core.py'])
        self.assertEqual(accepted['permissionDecision'], 'allow', accepted)
        alias = self.delegate(['./stockflow/core.py'])
        self.assertEqual(alias['permissionDecision'], 'deny', alias)
        self.assertIn('repeated identical', alias['permissionDecisionReason'])
        self.hook('SubagentStart', agent_type='algorithm-agent', agent_id='algorithm-child')
        stopped = self.hook('SubagentStop', agent_type='algorithm-agent', agent_id='algorithm-child',
                            last_assistant_message='Synthetic slice complete.\nMEMORY: NONE')
        self.assertIn('next smaller ALGORITHM slice', stopped['systemMessage'])
        self.python("""
import workflow_state as w
s=w.get_active_state('growth-session')
assert s.growth_recovery_guard_active and not w.can_finish_turn(s)[0]
""")
        final = self.delegate(['tests/test_core.py'], ['tests::final'], completed=['model'], residual=['tests'], final_slice=True)
        self.assertEqual(final['permissionDecision'], 'allow', final)
        backwards = self.delegate(['stockflow/util.py'])
        self.assertEqual(backwards['permissionDecision'], 'deny')
        self.assertIn('monotonic', backwards['permissionDecisionReason'])
        self.hook('SubagentStart', agent_type='algorithm-agent', agent_id='final-algorithm')
        self.hook('SubagentStop', agent_type='algorithm-agent', agent_id='final-algorithm',
                  last_assistant_message='Final synthetic slice complete.\nMEMORY: NONE')
        allowed_test = self.hook('PreToolUse', tool_name='agent', tool_input={
            'subagent_type':'test-agent','run_in_background':False,'prompt':'Verify the completed synthetic implementation.',
        })['hookSpecificOutput']
        self.assertEqual(allowed_test['permissionDecision'], 'allow', allowed_test)
        self.hook('SubagentStart', agent_type='test-agent', agent_id='final-test')
        self.assertTrue(self.state()['final_test_started'])
        self.hook('SubagentStop', agent_type='test-agent', agent_id='final-test', last_assistant_message='PASS\nMEMORY: NONE')
        self.python("""
import workflow_state as w
s=w.get_active_state('growth-session')
assert not s.growth_recovery_guard_active
assert w.can_finish_turn(s)[0]
""")

    def test_test_agent_pretool_is_blocked_during_recovery(self):
        result = self.hook('PreToolUse', tool_name='agent', tool_input={
            'subagent_type':'test-agent','run_in_background':False,'prompt':'Verify current implementation.',
        })['hookSpecificOutput']
        self.assertEqual(result['permissionDecision'], 'deny', result)

    def test_test_agent_start_cannot_mutate_verification_during_recovery(self):
        result = self.hook('SubagentStart', agent_type='test-agent', agent_id='test-child')
        self.assertFalse(result['continue'])
        self.assertFalse(self.state()['final_test_started'])
        self.python("import workflow_state as w\nassert w.get_agent_root_turn_id('growth-session','test-child') is None")
