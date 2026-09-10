/**
 * code-constants —— Code 资产页的常量、类型与纯工具函数。
 * 从 CodeSourcesPanel.tsx 拆出。
 */
export type SubView = 'list' | 'detail';
export type ViewMode = 'card' | 'list';
export type StatusFilter = 'all' | 'ready' | 'processing' | 'error';
export type ScopeTab = 'team' | 'fixed';

export function formatShortTime(iso?: string | null): string {
  if (!iso) return '—';
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '—';
  const pad = (value: number) => String(value).padStart(2, '0');
  return `${pad(date.getMonth() + 1)}/${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

/**
 * 校验是否为合法的 Git 仓库地址（HTTPS 或 SSH）。
 * HTTPS: http:// 或 https://，host 含点，路径不含空格，以 .git 结尾。
 * SSH: git@host:path.git 格式（scp-style）。
 * 用正则而非 URL 解析 —— new URL() 会接受路径中的空格（如 /a b/repo.git），
 * 且不强制 .git 后缀，均不符合 code graph 注册的严格约束。
 */
const GIT_HTTP_URL_RE = /^https?:\/\/[^\s/]+\.[^\s/]+\/[^\s]+\.git$/i;
const GIT_SSH_URL_RE = /^git@[^\s:]+:[^\s]+\.git$/i;
export function isValidGitRepoUrl(raw: string): boolean {
  const trimmed = raw.trim();
  return GIT_HTTP_URL_RE.test(trimmed) || GIT_SSH_URL_RE.test(trimmed);
}
// 保留旧函数名以兼容（已 deprecated）
export function isValidGitHttpUrl(raw: string): boolean {
  return isValidGitRepoUrl(raw);
}

/**
 * 从 Git URL 提取可读的仓库名称。
 *
 * repo_name 可能为空（旧数据），此时回退到 URL 会显得很长。
 * 这里从 URL 中提取最后两段路径作为 `namespace/repo` 格式：
 *   https://gitlab.example.com/namespace/repo.git → namespace/repo
 *   https://github.com/org/project.git → org/project
 *   https://git.woa.com/group/sub/repo.git → sub/repo
 * 如果只有一段路径，直接返回该段（去掉 .git 后缀）。
 * 解析失败时返回原始 URL（保底）。
 */
export function formatRepoName(repoName: string, repoUrl: string): string {
  if (repoName && !repoName.startsWith('http')) return repoName;
  const url = repoName || repoUrl;
  if (!url) return '';
  try {
    const parsed = new URL(url);
    const segments = parsed.pathname.replace(/\.git$/, '').split('/').filter(Boolean);
    if (segments.length >= 2) return `${segments[segments.length - 2]}/${segments[segments.length - 1]}`;
    if (segments.length === 1) return segments[0];
  } catch {
    // fallback
  }
  return url;
}
