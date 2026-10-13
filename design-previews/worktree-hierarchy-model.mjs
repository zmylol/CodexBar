// Prototype state only. Directories identify nodes; branches never identify or order them.
export function createDemoState() {
  const directory = '/projects/codexbar';
  const worktrees = '/projects/codexbar-worktrees';
  return {
    schemaVersion: 1,
    activeDirectory: directory,
    projects: [{ directory, name: 'CodexBar', branches: ['main', 'dev', 'a', 'b', 'c', 'd', 'feature-x'] }],
    nodes: [
      { directory, projectDirectory: directory, parentDirectory: null, name: 'CodexBar', branch: 'main' },
      ...['a', 'b', 'c', 'd'].map(branch => ({
        directory: `${worktrees}/${branch}`,
        projectDirectory: directory,
        parentDirectory: ['c', 'd'].includes(branch) ? `${worktrees}/a` : directory,
        name: `worktree ${branch.toUpperCase()}`,
        branch,
      })),
    ],
  };
}

function text(value, label) {
  if (typeof value !== 'string' || !value.trim() || /[\u0000-\u001f\u007f]/u.test(value)) {
    throw new Error(`${label}不能为空或包含控制字符。`);
  }
  return value.trim();
}

export function normalizeDirectory(value) {
  const path = text(value, '工作目录');
  if (!path.startsWith('/')) throw new Error('工作目录需要使用绝对路径。');
  const parts = [];
  for (const part of path.split('/')) {
    if (part === '' || part === '.') continue;
    if (part === '..') {
      if (!parts.length) throw new Error('工作目录不能越过根目录。');
      parts.pop();
    } else {
      parts.push(part);
    }
  }
  return `/${parts.join('/')}`;
}

function nodeAt(state, directory) {
  const path = normalizeDirectory(directory);
  const node = state.nodes.find(candidate => candidate.directory === path);
  if (!node) throw new Error('找不到此工作目录。');
  return node;
}

export function getActiveNode(state) {
  return nodeAt(state, state.activeDirectory);
}

export function getChildren(state, parentDirectory) {
  const parent = parentDirectory === null ? null : normalizeDirectory(parentDirectory);
  // Array order is creation order, independent of branch names and the active directory.
  return state.nodes.filter(node => node.parentDirectory === parent);
}

export function selectDirectory(state, directory) {
  return { ...state, activeDirectory: nodeAt(state, directory).directory };
}

export function switchBranch(state, directory, value) {
  const node = nodeAt(state, directory);
  const branch = text(value, '分支名');
  const project = state.projects.find(candidate => candidate.directory === node.projectDirectory);
  if (!project.branches.includes(branch)) throw new Error('此项目没有这个分支。');
  return {
    ...state,
    nodes: state.nodes.map(candidate => candidate.directory === node.directory ? { ...candidate, branch } : candidate),
  };
}

export function createWorktree(state, parentDirectory, input) {
  const parent = nodeAt(state, parentDirectory);
  const directory = normalizeDirectory(input.directory);
  const name = text(input.name, '目录名称');
  const branch = text(input.branch, '分支名');
  if (state.nodes.some(node => node.directory === directory)) throw new Error('此工作目录已存在，不能重复创建节点。');
  const node = { directory, projectDirectory: parent.projectDirectory, parentDirectory: parent.directory, name, branch };
  return {
    ...state,
    activeDirectory: directory,
    nodes: [...state.nodes, node],
    projects: state.projects.map(project => project.directory === parent.projectDirectory
      ? { ...project, branches: project.branches.includes(branch) ? project.branches : [...project.branches, branch] }
      : project),
  };
}

export function serializeState(state) {
  return JSON.stringify(state);
}

export function restoreState(json) {
  let saved;
  try { saved = JSON.parse(json); } catch { throw new Error('保存的原型数据不是有效 JSON。'); }
  if (saved?.schemaVersion !== 1 || !Array.isArray(saved.projects) || !saved.projects.length
      || !Array.isArray(saved.nodes) || !saved.nodes.length) {
    throw new Error('保存的原型数据版本或结构不受支持。');
  }
  const projects = saved.projects.map(project => {
    if (!Array.isArray(project?.branches) || !project.branches.length) throw new Error('项目缺少分支列表。');
    return {
      directory: normalizeDirectory(project.directory),
      name: text(project.name, '项目名称'),
      branches: project.branches.map(branch => text(branch, '分支名')),
    };
  });
  const byProject = new Map(projects.map(project => [project.directory, project]));
  if (byProject.size !== projects.length) throw new Error('保存的数据包含重复项目。');
  const nodes = saved.nodes.map(node => ({
    directory: normalizeDirectory(node?.directory),
    projectDirectory: normalizeDirectory(node?.projectDirectory),
    parentDirectory: node?.parentDirectory === null ? null : normalizeDirectory(node?.parentDirectory),
    name: text(node?.name, '目录名称'),
    branch: text(node?.branch, '分支名'),
  }));
  const byDirectory = new Map(nodes.map(node => [node.directory, node]));
  if (byDirectory.size !== nodes.length) throw new Error('保存的数据包含重复工作目录。');
  for (const project of projects) {
    const root = byDirectory.get(project.directory);
    if (!root || root.projectDirectory !== project.directory || root.parentDirectory !== null) {
      throw new Error('项目的主目录或创建来源不正确。');
    }
  }
  for (const node of nodes) {
    const project = byProject.get(node.projectDirectory);
    if (!project || !project.branches.includes(node.branch)) throw new Error('工作目录的项目或分支不存在。');
    if (node.parentDirectory === null) {
      if (node.directory !== node.projectDirectory) throw new Error('Worktree 缺少创建来源。');
      continue;
    }
    const parent = byDirectory.get(node.parentDirectory);
    if (!parent || parent.projectDirectory !== node.projectDirectory) throw new Error('创建来源不存在或属于其他项目。');
    const visited = new Set([node.directory]);
    let ancestor = parent;
    while (ancestor) {
      if (visited.has(ancestor.directory)) throw new Error('创建来源包含循环关系。');
      visited.add(ancestor.directory);
      ancestor = byDirectory.get(ancestor.parentDirectory);
    }
  }
  const state = { schemaVersion: 1, activeDirectory: normalizeDirectory(saved.activeDirectory), projects, nodes };
  getActiveNode(state);
  return state;
}
