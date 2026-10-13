import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  createDemoState, createWorktree, getActiveNode, getChildren, normalizeDirectory,
  restoreState, selectDirectory, serializeState, switchBranch,
} from '../../design-previews/worktree-hierarchy-model.mjs';

const topology = state => state.nodes.map(({ directory, parentDirectory, projectDirectory, name }) =>
  ({ directory, parentDirectory, projectDirectory, name }));

test('demo preserves the requested root, A/B and A -> C/D creation tree', () => {
  const state = createDemoState();
  const root = getActiveNode(state);
  assert.equal(root.branch, 'main');
  const [a, b] = getChildren(state, root.directory);
  assert.deepEqual([a.name, b.name], ['worktree A', 'worktree B']);
  assert.deepEqual(getChildren(state, a.directory).map(node => node.name), ['worktree C', 'worktree D']);
  assert.equal(getChildren(state, b.directory).length, 0);
  assert.equal(getChildren(state, null).length, 1);
});

test('root and child branch switches change labels without moving or adding nodes', () => {
  const initial = createDemoState();
  const root = getActiveNode(initial);
  const a = getChildren(initial, root.directory)[0];
  const switchedRoot = switchBranch(initial, root.directory, 'dev');
  const selected = selectDirectory(switchedRoot, a.directory);
  const switchedChild = switchBranch(selected, a.directory, 'feature-x');
  assert.deepEqual(topology(switchedChild), topology(initial));
  assert.equal(getActiveNode(switchedChild).branch, 'feature-x');
  assert.equal(switchedChild.nodes.find(node => node.directory === root.directory).branch, 'dev');
  assert.equal(getActiveNode(initial).branch, 'main');
  assert.equal(a.branch, 'a');
});

test('branch bar follows directory selection without transferring branches', () => {
  const state = createDemoState();
  for (const node of state.nodes) {
    const selected = selectDirectory(state, node.directory);
    assert.equal(getActiveNode(selected).directory, node.directory);
    assert.equal(getActiveNode(selected).branch, node.branch);
    assert.deepEqual(selected.nodes, state.nodes);
  }
});

test('creation uses its captured source even if another directory becomes active', () => {
  const initial = createDemoState();
  const [a, b] = getChildren(initial, initial.activeDirectory);
  const moved = selectDirectory(initial, b.directory);
  const created = createWorktree(moved, a.directory, {
    name: 'worktree E', directory: '/elsewhere/e', branch: 'experiment/e',
  });
  assert.equal(getActiveNode(created).directory, '/elsewhere/e');
  assert.equal(getActiveNode(created).parentDirectory, a.directory);
  assert.equal(getChildren(created, b.directory).length, 0);
  assert.deepEqual(topology(created).slice(0, -1), topology(initial));
  assert.ok(created.projects[0].branches.includes('experiment/e'));
  assert.equal(initial.nodes.length, 5);
});

test('creation supports more than three levels and does not infer parents from filesystem nesting', () => {
  let state = createDemoState();
  for (let depth = 0; depth < 8; depth += 1) {
    const parent = state.activeDirectory;
    state = createWorktree(state, parent, {
      name: `Level ${depth}`, directory: `/independent-${depth}`, branch: `branch-${depth}`,
    });
    assert.equal(getActiveNode(state).parentDirectory, parent);
  }
  assert.equal(state.nodes.length, 13);
  assert.deepEqual(restoreState(serializeState(state)), state);
});

test('identical branch names never merge or reparent directories', () => {
  const initial = createDemoState();
  const changed = initial.nodes.reduce((state, node) => switchBranch(state, node.directory, 'main'), initial);
  assert.deepEqual(topology(changed), topology(initial));
  assert.equal(new Set(changed.nodes.map(node => node.directory)).size, 5);
});

test('directory aliases normalize to a single identity and duplicate creation is rejected', () => {
  const state = createDemoState();
  assert.equal(normalizeDirectory('/projects/./codexbar/../codexbar/'), '/projects/codexbar');
  assert.equal(getActiveNode(selectDirectory(state, '/projects/./codexbar/')).directory, state.activeDirectory);
  assert.throws(() => createWorktree(state, state.activeDirectory, {
    name: 'Duplicate', directory: '/projects/./codexbar/', branch: 'duplicate',
  }));
  for (const directory of ['', 'relative/path', '/../../escape']) {
    assert.throws(() => normalizeDirectory(directory));
  }
});

test('unknown directories and unavailable branches leave existing state untouched', () => {
  const state = createDemoState();
  const before = serializeState(state);
  assert.throws(() => selectDirectory(state, '/missing'));
  assert.throws(() => switchBranch(state, '/missing', 'main'));
  assert.throws(() => switchBranch(state, state.activeDirectory, 'not-listed'));
  assert.throws(() => createWorktree(state, '/missing', { name: 'X', directory: '/x', branch: 'x' }));
  assert.throws(() => createWorktree(state, state.activeDirectory, { name: ' ', directory: '/x', branch: 'x' }));
  assert.throws(() => createWorktree(state, state.activeDirectory, { name: 'X', directory: '/x', branch: ' ' }));
  assert.equal(serializeState(state), before);
});

test('saved directories, branch labels, active directory and sibling order survive reload', () => {
  let state = createDemoState();
  state = switchBranch(state, state.activeDirectory, 'dev');
  state = selectDirectory(state, state.nodes[3].directory);
  assert.deepEqual(restoreState(serializeState(state)), state);
});

test('restore refuses missing provenance, duplicate identities, cycles and cross-project parents', () => {
  const corruptions = [
    state => { state.schemaVersion = 99; },
    state => { state.activeDirectory = '/missing'; },
    state => { state.nodes.push({ ...state.nodes[0] }); },
    state => { state.nodes[1].parentDirectory = '/missing'; },
    state => { state.nodes[1].parentDirectory = state.nodes[1].directory; },
    state => { state.nodes[1].parentDirectory = state.nodes[3].directory; },
    state => { state.nodes[0].parentDirectory = state.nodes[1].directory; },
    state => { state.nodes[1].parentDirectory = null; },
    state => { state.nodes[1].branch = 'not-listed'; },
    state => { state.projects.push({ directory: '/other', name: 'Other', branches: ['main'] });
      state.nodes.push({ directory: '/other', projectDirectory: '/other', parentDirectory: null, name: 'Other', branch: 'main' });
      state.nodes[1].parentDirectory = '/other'; },
  ];
  assert.throws(() => restoreState('{broken'));
  assert.throws(() => restoreState('null'));
  for (const mutate of corruptions) {
    const state = createDemoState();
    mutate(state);
    assert.throws(() => restoreState(JSON.stringify(state)));
  }
});
