import {
  createDemoState, selectDirectory, switchBranch, createWorktree,
  serializeState, restoreState, getChildren, getActiveNode,
} from './worktree-hierarchy-model.mjs';

const storageKey = 'codexbar.worktree-hierarchy.v1';
const element = (id) => document.getElementById(id);
const treeButtons = new Map();
let state = createDemoState();
let storageNeedsReset = false;
let capturedParent = null;
let directoryWasEdited = false;

function showStorageError(message) {
  element('storage-error').textContent = message;
  element('storage-error').hidden = !message;
}

try {
  const saved = localStorage.getItem(storageKey);
  if (saved !== null) state = restoreState(saved);
} catch (error) {
  storageNeedsReset = true;
  showStorageError(`无法读取已保存的演示：${error.message}。当前使用临时演示，改动不会覆盖原数据。点击“重置演示”可重新保存。`);
}

function persist() {
  if (storageNeedsReset) return;
  try {
    localStorage.setItem(storageKey, serializeState(state));
    showStorageError('');
  } catch (error) {
    showStorageError(`当前改动尚未保存：${error.message}。你可以继续体验，刷新页面后可能丢失本次改动。`);
  }
}

function make(tag, className, content) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (content !== undefined) node.textContent = content;
  return node;
}

function directoryIcon(isRoot) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 20 20');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('aria-hidden', 'true');
  svg.classList.add('node-icon');
  const path = document.createElementNS(svg.namespaceURI, 'path');
  path.setAttribute('d', isRoot
    ? 'M2.5 6V4.5A1.5 1.5 0 0 1 4 3h4l2 2h6A1.5 1.5 0 0 1 17.5 6.5v9A1.5 1.5 0 0 1 16 17H4a1.5 1.5 0 0 1-1.5-1.5V6Zm0 1h15'
    : 'M6 3v8a3 3 0 0 0 3 3h5M6 3l-2 2m2-2 2 2m6 9-2-2m2 2-2 2');
  path.setAttribute('stroke', 'currentColor');
  path.setAttribute('stroke-width', '1.3');
  path.setAttribute('stroke-linecap', 'round');
  path.setAttribute('stroke-linejoin', 'round');
  svg.append(path);
  return svg;
}

function activate(directory) {
  const next = selectDirectory(state, directory);
  commit(next, `当前目录：${getActiveNode(next).name}。分支 bar 已同步。`);
  treeButtons.get(directory)?.focus();
}

function renderTree(parentDirectory, container) {
  for (const node of getChildren(state, parentDirectory)) {
    const item = make('li');
    const button = make('button', 'directory-row');
    button.type = 'button';
    button.dataset.directory = node.directory;
    button.setAttribute('aria-current', String(node.directory === state.activeDirectory));
    button.setAttribute('aria-label', `${node.name}，分支 ${node.branch}，目录 ${node.directory}`);
    button.title = `${node.name} · ${node.branch}\n${node.directory}`;
    button.append(directoryIcon(node.parentDirectory === null), make('span', 'node-name', node.name), make('span', 'node-branch', node.branch));
    button.addEventListener('click', () => activate(node.directory));
    treeButtons.set(node.directory, button);
    item.append(button);
    if (getChildren(state, node.directory).length > 0) {
      const children = make('ul');
      renderTree(node.directory, children);
      item.append(children);
    }
    container.append(item);
  }
}

function renderBreadcrumbs(active) {
  const chain = [];
  let current = active;
  while (current) {
    chain.unshift(current);
    current = state.nodes.find((node) => node.directory === current.parentDirectory);
  }
  const list = element('breadcrumbs');
  list.replaceChildren();
  chain.forEach((node, index) => {
    const item = make('li');
    if (index === chain.length - 1) {
      item.textContent = node.name;
      item.setAttribute('aria-current', 'location');
    } else {
      const button = make('button', '', node.name);
      button.type = 'button';
      button.title = node.directory;
      button.addEventListener('click', () => activate(node.directory));
      item.append(button);
    }
    list.append(item);
  });
}

function renderChildren(active) {
  const children = getChildren(state, active.directory);
  element('child-count').textContent = `${children.length} 个 worktree`;
  const panel = element('children-panel');
  panel.replaceChildren();
  if (children.length === 0) {
    panel.append(make('p', 'empty-children', '还没有从此目录创建的 worktree。新建一个，继续向下扩展。'));
    return;
  }
  panel.append(make('p', 'children-caption', '从此目录创建'));
  const list = make('ul', 'child-list');
  for (const node of children) {
    const item = make('li');
    const button = make('button', 'child-link');
    button.type = 'button';
    button.title = `${node.name} · ${node.branch}\n${node.directory}`;
    button.append(make('span', '', node.name), make('span', 'child-branch', `· ${node.branch}`));
    button.addEventListener('click', () => activate(node.directory));
    item.append(button);
    list.append(item);
  }
  panel.append(list);
}

function render() {
  const active = getActiveNode(state);
  const project = state.projects.find((item) => item.directory === active.projectDirectory);
  const parent = state.nodes.find((node) => node.directory === active.parentDirectory);
  treeButtons.clear();
  element('directory-tree').replaceChildren();
  renderTree(null, element('directory-tree'));
  element('node-count').textContent = `${state.nodes.length} 个目录`;
  renderBreadcrumbs(active);
  element('directory-heading').textContent = active.name;
  element('active-path').textContent = active.directory;
  element('active-path').title = active.directory;
  element('directory-kind').textContent = parent ? 'Worktree' : '项目根目录';
  element('project-name').textContent = project.name;
  element('parent-name').textContent = parent ? parent.name : '— 项目根目录';
  element('parent-name').title = parent?.directory ?? '根目录没有创建来源';
  const branchSelect = element('branch-select');
  branchSelect.replaceChildren(...project.branches.map((branch) => {
    const option = make('option', '', branch);
    option.value = branch;
    return option;
  }));
  branchSelect.value = active.branch;
  branchSelect.title = `${active.directory} · ${active.branch}`;
  renderChildren(active);
}

function commit(next, message) {
  state = next;
  render();
  persist();
  element('action-status').textContent = message;
}

element('branch-select').addEventListener('change', (event) => {
  const active = getActiveNode(state);
  try {
    commit(switchBranch(state, active.directory, event.target.value), `${active.name} 已切换到 ${event.target.value}；创建层级保持不变。`);
  } catch (error) {
    event.target.value = active.branch;
    element('action-status').textContent = `无法切换分支：${error.message}`;
  }
});

element('create-worktree').addEventListener('click', () => {
  capturedParent = getActiveNode(state);
  directoryWasEdited = false;
  element('create-form').reset();
  element('creation-error').hidden = true;
  element('creation-source-name').textContent = capturedParent.name;
  element('creation-source-path').textContent = capturedParent.directory;
  element('worktree-directory').value = `${capturedParent.projectDirectory}-worktrees/`;
  element('create-dialog').showModal();
  element('worktree-name').focus();
});

element('worktree-directory').addEventListener('input', () => { directoryWasEdited = true; });
element('worktree-name').addEventListener('input', (event) => {
  if (directoryWasEdited || !capturedParent) return;
  const slug = event.target.value.trim().replace(/[\s/\\]+/g, '-');
  element('worktree-directory').value = `${capturedParent.projectDirectory}-worktrees/${slug}`;
});

element('create-form').addEventListener('submit', (event) => {
  event.preventDefault();
  if (!capturedParent) return;
  try {
    const next = createWorktree(state, capturedParent.directory, {
      name: element('worktree-name').value,
      directory: element('worktree-directory').value,
      branch: element('worktree-branch').value,
    });
    const sourceName = capturedParent.name;
    const created = getActiveNode(next);
    commit(next, `已从 ${sourceName} 创建 ${created.name}，并切换到新工作目录。`);
    element('create-dialog').close();
    treeButtons.get(created.directory)?.focus();
  } catch (error) {
    element('creation-error').textContent = error.message;
    element('creation-error').hidden = false;
  }
});

element('create-dialog').addEventListener('close', () => { capturedParent = null; });
document.querySelectorAll('[data-close]').forEach((button) => {
  button.addEventListener('click', () => element(button.dataset.close).close());
});
element('reset-demo').addEventListener('click', () => element('reset-dialog').showModal());
element('confirm-reset').addEventListener('click', () => {
  storageNeedsReset = false;
  commit(createDemoState(), '已恢复初始结构：A、B 从项目根目录创建，C、D 从 A 创建。');
  element('reset-dialog').close();
  treeButtons.get(state.activeDirectory)?.focus();
});

render();
