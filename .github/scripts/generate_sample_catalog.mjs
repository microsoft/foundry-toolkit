// @ts-check
/**
 * Generate samples/hosted-agent/sample-catalog.json from the foundry-samples repository.
 *
 * Walks the hosted-agents tree in microsoft-foundry/foundry-samples once via
 * the git-tree API, parses each sample's agent.yaml (+ optional
 * agent.manifest.yaml) for protocol and model requirements, derives
 * displayName from the directory name, and — when AZURE_OPENAI_* secrets are
 * set — fills the description with a short LLM-generated sentence sourced
 * from the sample's README.md.
 *
 * Usage:
 *   node generate_sample_catalog.mjs <commitSha>
 *
 * Environment variables:
 *   GITHUB_TOKEN        Optional GitHub token for API authentication.
 *   REPO_ROOT           Repository root (defaults to two levels up from this script).
 *   SAMPLES_REPO_URL    Source repo URL (defaults to https://github.com/microsoft-foundry/foundry-samples/).
 *   AZURE_OPENAI_*      Optional; when set, descriptions are LLM-generated.
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, appendFileSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const REPO_ROOT = process.env.REPO_ROOT || resolve(__dirname, '..', '..');
const SAMPLES_REPO_URL = process.env.SAMPLES_REPO_URL || 'https://github.com/microsoft-foundry/foundry-samples/';
const SAMPLES_REPO_API = 'https://api.github.com/repos/microsoft-foundry/foundry-samples';
const OUTPUT_PATH = join(REPO_ROOT, 'samples', 'hosted-agent', 'sample-catalog.json');
const OVERRIDES_PATH = join(REPO_ROOT, 'samples', 'hosted-agent', 'sample-overrides.json');

const GITHUB_TOKEN = process.env.GITHUB_TOKEN || '';

const LANGUAGES = ['python', 'csharp'];
const FRAMEWORKS = ['agent-framework', 'bring-your-own', 'langgraph'];

/** @type {Record<string, {title: string, placeholder: string, options: Record<string, string>}>} */
const DIMENSION_DEFAULTS = {
    language: {
        title: 'Select a Language',
        placeholder: 'Choose the language for your agent',
        options: {
            python: 'Python',
            csharp: 'C# (.NET)',
        },
    },
    framework: {
        title: 'Select a Framework',
        placeholder: 'Choose the framework for your agent',
        // Insertion order here drives the option order in the generated catalog
        // (see buildDimensions). Keep the most actively promoted framework first.
        options: {
            'copilot-sdk': 'Copilot SDK',
            'agent-framework': 'Agent Framework',
            'bring-your-own': 'Bring Your Own',
            'langgraph': 'LangGraph',
        },
    },
    protocol: {
        title: 'Select a Protocol',
        placeholder: 'Choose the protocol for your agent',
        options: {
            responses: 'Responses API',
            invocations: 'Invocations API',
        },
    },
};

const TEMPLATE_SELECTION = {
    title: 'Select a Template',
    placeholder: 'Choose a template for your agent',
};

// Path segments must be alphanumeric, hyphens, underscores, or dots
const SAFE_PATH_SEGMENT = /^[a-zA-Z0-9._-]+$/;

// Path segments that should never surface as catalog templates, even when
// they contain a valid `agent.yaml`. Use this to drop upstream folders we
// don't want in the picker yet (e.g. `invocations_ws` LiveKit samples).
const BLOCKED_PATH_SEGMENTS = new Set(['invocations_ws']);

/**
 * Collected anomaly messages surfaced in CI step summary so reviewers do not
 * silently merge a catalog with missing/derived data. Always populated, even
 * when running locally without a step-summary file.
 * @type {string[]}
 */
const warnings = [];

/**
 * Record a warning that should appear in the CI step summary, and mirror it
 * to stderr for live log visibility.
 * @param {string} message
 */
function warn(message) {
    warnings.push(message);
    console.warn(`WARN: ${message}`);
}

/**
 * @param {string} url
 * @returns {Promise<any>}
 */
async function fetchJson(url) {
    /** @type {Record<string, string>} */
    const headers = {
        'User-Agent': 'microsoft-foundry-for-vscode-sync',
        Accept: 'application/vnd.github+json',
    };
    if (GITHUB_TOKEN) {
        headers['Authorization'] = `Bearer ${GITHUB_TOKEN}`;
    }
    const response = await fetch(url, { headers });
    if (!response.ok) {
        throw new Error(`HTTP ${response.status} for ${url}`);
    }
    return response.json();
}

/**
 * @param {string} url
 * @returns {Promise<string>}
 */
async function fetchText(url) {
    /** @type {Record<string, string>} */
    const headers = { 'User-Agent': 'microsoft-foundry-for-vscode-sync' };
    if (GITHUB_TOKEN) {
        headers['Authorization'] = `Bearer ${GITHUB_TOKEN}`;
    }
    const response = await fetch(url, { headers });
    if (!response.ok) {
        throw new Error(`HTTP ${response.status} for ${url}`);
    }
    return response.text();
}

/**
 * Validate that a path segment is safe: no traversal, no special chars, no
 * leading-dot directories (e.g. `.claude`, `.github`) which are tooling
 * metadata, not sample templates.
 * @param {string} segment
 * @returns {boolean}
 */
function isSafePathSegment(segment) {
    if (segment === '.' || segment === '..' || segment.startsWith('.')) {
        return false;
    }
    return SAFE_PATH_SEGMENT.test(segment);
}

/**
 * Parse the commit SHA from the CLI argument.
 * @returns {string}
 */
function parseCommitShaArg() {
    const sha = process.argv[2] || '';
    if (!sha) {
        console.error('Usage: node generate_sample_catalog.mjs <commitSha>');
        process.exit(1);
    }
    if (!/^[0-9a-f]{7,40}$/i.test(sha)) {
        throw new Error(`Invalid commit SHA: "${sha}"`);
    }
    return sha;
}

/**
 * Fetch the full recursive git tree for a ref. One API call covers the entire
 * `samples/` hierarchy, which is much cheaper (and more accurate) than walking
 * the `/contents/` endpoint level-by-level — and it lets us discover samples
 * at arbitrary nesting depths (e.g. `bring-your-own/voicelive/<template>`)
 * without hard-coding the layout.
 *
 * @param {string} ref
 * @returns {Promise<{tree: Array<{path: string, type: string}>, truncated: boolean}>}
 */
async function fetchRepoTree(ref) {
    const data = await fetchJson(`${SAMPLES_REPO_API}/git/trees/${ref}?recursive=1`);
    const tree = Array.isArray(data?.tree) ? data.tree : [];
    return { tree, truncated: Boolean(data?.truncated) };
}

/**
 * Find sample template directories under a `hosted-agents/<framework>/` prefix.
 * A template is identified by the presence of an `agent.yaml`. When nested
 * agent.yaml files exist (e.g. a sub-agent declared inside a parent sample),
 * only the OUTERMOST one is treated as a catalog template — the inner files
 * are part of the parent sample. Hidden directories (segments beginning with
 * `.`, e.g. `.claude/skills`) are skipped, as are segments that fail the
 * `SAFE_PATH_SEGMENT` check.
 *
 * @param {Array<{path: string, type: string}>} tree
 * @param {string} prefix Path prefix ending in `/`, e.g. `samples/python/hosted-agents/agent-framework/`.
 * @returns {string[]} Repo-relative template directory paths, outermost only.
 */
function findTemplateDirsUnder(tree, prefix) {
    const candidates = tree
        .filter((entry) => entry.type === 'blob' && entry.path.startsWith(prefix) && entry.path.endsWith('/agent.yaml'))
        .map((entry) => entry.path.slice(0, -'/agent.yaml'.length))
        .filter((dir) => {
            const rel = dir.slice(prefix.length);
            if (!rel) {
                return false;
            }
            const segments = rel.split('/');
            if (!segments.every((seg) => isSafePathSegment(seg))) {
                return false;
            }
            // Drop templates that live under a blocked segment (e.g.
            // `invocations_ws`) so upstream additions don't auto-leak into
            // the catalog before we explicitly opt them in.
            return !segments.some((seg) => BLOCKED_PATH_SEGMENTS.has(seg));
        })
        // Lexicographic sort serves two purposes: (1) a parent path always
        // sorts before its descendants, so the `startsWith` check below
        // correctly keeps only the outermost agent.yaml; (2) it preserves
        // upstream's `NN-` numeric prefix ordering in the picker.
        .sort();

    /** @type {string[]} */
    const outermost = [];
    for (const dir of candidates) {
        if (!outermost.some((existing) => dir.startsWith(`${existing}/`))) {
            outermost.push(dir);
        }
    }
    return outermost;
}

/**
 * Infer protocol when `agent.yaml` does not declare one explicitly. Looks for
 * a `responses` or `invocations` segment in the path, then for the substring
 * in the leaf directory name (common for samples like
 * `hello-world-invocations-voicelive`). Falls back to `responses` and emits a
 * warning so the catalog reviewer can verify the choice.
 *
 * @param {string} templatePath
 * @returns {'responses' | 'invocations'}
 */
function inferProtocolFromPath(templatePath) {
    const segments = templatePath.split('/');
    if (segments.includes('responses')) {
        return 'responses';
    }
    if (segments.includes('invocations')) {
        return 'invocations';
    }
    const leaf = segments[segments.length - 1].toLowerCase();
    if (leaf.includes('invocations')) {
        return 'invocations';
    }
    if (leaf.includes('responses')) {
        return 'responses';
    }
    warn(`Could not infer protocol for "${templatePath}"; defaulting to "responses". Add a "- protocol:" entry to agent.yaml or a sample-overrides.json entry to silence this.`);
    return 'responses';
}

/**
 * Minimal parser for agent.yaml. Extracts the declared protocol(s) and
 * whether the sample exposes the AZURE_AI_MODEL_DEPLOYMENT_NAME env var
 * (used as a heuristic for `requiresModel`). Does NOT use eval or a real
 * YAML library — a regex-y scan is sufficient for our two fields.
 * @param {string} content
 * @returns {{ protocols: Array<'responses' | 'invocations'>, hasModelEnv: boolean }}
 */
function parseAgentYaml(content) {
    /** @type {{ protocols: Array<'responses' | 'invocations'>, hasModelEnv: boolean }} */
    const result = { protocols: [], hasModelEnv: false };

    for (const line of content.split('\n')) {
        const stripped = line.trim();
        if (stripped.startsWith('- protocol:')) {
            const value = stripped.split(':')[1]?.trim();
            if (value === 'responses' || value === 'invocations') {
                result.protocols.push(value);
            }
        }
        if (stripped.startsWith('- name:') && stripped.includes('AZURE_AI_MODEL_DEPLOYMENT_NAME')) {
            result.hasModelEnv = true;
        }
    }

    return result;
}

/**
 * Fetch and parse agent.yaml for a sample directory.
 * @param {string} samplePath
 * @param {string} ref
 * @returns {Promise<{ protocols: Array<'responses' | 'invocations'>, hasModelEnv: boolean } | null>}
 */
async function fetchAgentYaml(samplePath, ref) {
    const rawUrl = `https://raw.githubusercontent.com/microsoft-foundry/foundry-samples/${ref}/${samplePath}/agent.yaml`;
    try {
        const content = await fetchText(rawUrl);
        return parseAgentYaml(content);
    } catch {
        return null;
    }
}

/**
 * Minimal parser for agent.manifest.yaml — detects whether the manifest
 * declares a top-level `resources:` list containing `kind: model`. Matches
 * both `- kind: model` and the multi-line continuation form, and limits
 * scanning to the `resources:` block to avoid false positives.
 * @param {string} content
 * @returns {{ hasModelResource: boolean }}
 */
function parseAgentManifestYaml(content) {
    let inResources = false;
    for (const rawLine of content.split('\n')) {
        const stripped = rawLine.trim();
        // Detect top-level key (column 0, e.g. `resources:`, `metadata:`).
        if (/^[A-Za-z_][\w-]*:/.test(rawLine)) {
            inResources = stripped.startsWith('resources:');
            continue;
        }
        if (!inResources) {
            continue;
        }
        // Strip optional `- ` so the inline and continuation forms both match.
        const withoutDash = stripped.replace(/^-\s+/, '');
        if (withoutDash.startsWith('kind:')) {
            const value = withoutDash.substring('kind:'.length).trim().replace(/^["']|["']$/g, '');
            if (value === 'model') {
                return { hasModelResource: true };
            }
        }
    }
    return { hasModelResource: false };
}

/**
 * Fetch and parse agent.manifest.yaml for a sample directory.
 * @param {string} samplePath
 * @param {string} ref
 * @returns {Promise<{ hasModelResource: boolean } | null>}
 */
async function fetchAgentManifestYaml(samplePath, ref) {
    const rawUrl = `https://raw.githubusercontent.com/microsoft-foundry/foundry-samples/${ref}/${samplePath}/agent.manifest.yaml`;
    try {
        const content = await fetchText(rawUrl);
        return parseAgentManifestYaml(content);
    } catch {
        return null;
    }
}

// Azure OpenAI configuration (from GitHub Secrets via env vars)
const AZURE_OPENAI_ENDPOINT = process.env.AZURE_OPENAI_ENDPOINT || '';
const AZURE_OPENAI_API_KEY = process.env.AZURE_OPENAI_API_KEY || '';
const AZURE_OPENAI_DEPLOYMENT = process.env.AZURE_OPENAI_DEPLOYMENT || 'gpt-4o-mini';

/**
 * Fetch README.md content for a sample directory.
 * @param {string} samplePath
 * @param {string} ref
 * @returns {Promise<string | null>}
 */
async function fetchReadme(samplePath, ref) {
    const rawUrl = `https://raw.githubusercontent.com/microsoft-foundry/foundry-samples/${ref}/${samplePath}/README.md`;
    try {
        return await fetchText(rawUrl);
    } catch {
        return null;
    }
}

/**
 * Call Azure OpenAI to generate a description from README content. We
 * intentionally do NOT ask the LLM for displayName — the folder name (with
 * numeric-prefix stripped, dashes turned into spaces, and Title Case)
 * produces more consistent results across the catalog and is easier for PMs
 * to predict at review time.
 *
 * @param {string} readmeContent
 * @param {string} samplePath
 * @returns {Promise<{ description: string } | null>}
 */
async function generateWithLLM(readmeContent, samplePath) {
    if (!AZURE_OPENAI_ENDPOINT || !AZURE_OPENAI_API_KEY) {
        return null;
    }

    const apiUrl = `${AZURE_OPENAI_ENDPOINT}/openai/deployments/${AZURE_OPENAI_DEPLOYMENT}/chat/completions?api-version=2024-08-01-preview`;

    const systemPrompt = `You generate one-sentence descriptions for a VS Code template picker.
The user has already selected language, framework, and protocol before seeing these items, so the description must NOT repeat those choices.

Rules:
- One sentence, max 100 characters
- Plain text, no markdown
- Describe what the sample does, not how it is implemented
- Do NOT include language names, protocol names, framework names, or words like "Sample" / "Demo"

Examples:
  {"description": "Minimal agent that echoes a response from a Foundry model."}
  {"description": "Conversational agent with multi-turn session history."}
  {"description": "Agent with local function tools for hotel search."}
  {"description": "Agent that discovers and invokes tools from a remote MCP server."}
  {"description": "Agent that saves and retrieves notes using function calling."}

Respond ONLY with a JSON object: {"description": "..."}`;

    const userPrompt = `Path: ${samplePath}

README.md:
${readmeContent.substring(0, 2000)}`;

    const body = {
        messages: [
            { role: 'system', content: systemPrompt },
            { role: 'user', content: userPrompt },
        ],
        temperature: 0,
        max_tokens: 120,
    };

    try {
        const response = await fetch(apiUrl, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'api-key': AZURE_OPENAI_API_KEY,
            },
            body: JSON.stringify(body),
        });

        if (!response.ok) {
            warn(`LLM API returned ${response.status} for ${samplePath}; description will be left empty.`);
            return null;
        }

        const data = await response.json();
        const content = data.choices?.[0]?.message?.content?.trim();
        if (!content) {
            return null;
        }

        // Parse JSON response — strip markdown code fences if present
        const jsonStr = content.replace(/^```json\s*/, '').replace(/\s*```$/, '');
        const parsed = JSON.parse(jsonStr);

        const description = typeof parsed.description === 'string' ? parsed.description.trim() : '';
        if (!description) {
            return null;
        }

        return { description };
    } catch (/** @type {any} */ err) {
        warn(`LLM call failed for ${samplePath}: ${err.message}`);
        return null;
    }
}

/**
 * Brand and acronym casing overrides applied during displayName derivation.
 * Keys are lower-case tokens; values are the canonical user-facing rendering.
 * Add entries here when a new acronym or brand appears in a sample folder
 * name so the template picker doesn't show "Github" / "Mcp" / "Sdk".
 * @type {Record<string, string>}
 */
const DISPLAY_NAME_TOKEN_CASING = {
    ag: 'AG',
    ai: 'AI',
    api: 'API',
    aws: 'AWS',
    cli: 'CLI',
    gcp: 'GCP',
    github: 'GitHub',
    llm: 'LLM',
    mcp: 'MCP',
    openai: 'OpenAI',
    rag: 'RAG',
    sdk: 'SDK',
    sso: 'SSO',
    ui: 'UI',
};

/**
 * Derive a displayName from the template's directory name. Strips a leading
 * numeric ordering prefix (`09-`, `12_`) so upstream reorderings don't bleed
 * into the picker, then converts dash/underscore tokens into Title Case
 * words and applies `DISPLAY_NAME_TOKEN_CASING` for known acronyms/brands:
 * `09-declarative-customer-support` -> `Declarative Customer Support`,
 * `azure-search-rag` -> `Azure Search RAG`.
 *
 * @param {string} samplePath
 * @returns {string}
 */
function displayNameFromPath(samplePath) {
    const dirName = samplePath.split('/').pop() || '';
    return dirName
        .replace(/^\d+[-_]/, '')
        .split(/[-_]/)
        .filter((w) => w.length > 0)
        .map((w) => DISPLAY_NAME_TOKEN_CASING[w.toLowerCase()] ?? (w.charAt(0).toUpperCase() + w.slice(1)))
        .join(' ');
}

/**
 * Scan the foundry-samples repo and build the flat template list. Uses one
 * recursive git-tree call to enumerate every `agent.yaml` under each
 * `<language>/hosted-agents/<framework>/` prefix, regardless of intermediate
 * directories. This supports both the canonical layout
 * (`<framework>/<protocol>/<template>`), the flat layout
 * (`<framework>/<template>`), and category-grouped layouts such as
 * `bring-your-own/voicelive/hello-world-invocations-voicelive`.
 *
 * @param {string} commitSha
 * @returns {Promise<Array<{language: string, framework: string, protocol: string, displayName: string, description: string, path: string, requiresModel: boolean}>>}
 */
async function scanTemplates(commitSha) {
    /** @type {Array<{language: string, framework: string, protocol: string, displayName: string, description: string, path: string, requiresModel: boolean}>} */
    const templates = [];

    const { tree, truncated } = await fetchRepoTree(commitSha);
    if (truncated) {
        warn(`GitHub git-tree API returned truncated=true for ${commitSha}; some samples may be missing from the catalog. Consider pinning to a smaller subtree or re-running.`);
    }

    for (const language of LANGUAGES) {
        for (const framework of FRAMEWORKS) {
            const prefix = `samples/${language}/hosted-agents/${framework}/`;
            const templateDirs = findTemplateDirsUnder(tree, prefix);

            for (const templatePath of templateDirs) {
                const agentInfo = await fetchAgentYaml(templatePath, commitSha);
                if (!agentInfo) {
                    warn(`Could not fetch or parse agent.yaml for "${templatePath}"; skipping this template.`);
                    continue;
                }

                /** @type {'responses' | 'invocations'} */
                const protocol = agentInfo.protocols.length > 0
                    ? agentInfo.protocols[0]
                    : inferProtocolFromPath(templatePath);

                let requiresModel = agentInfo.hasModelEnv;
                // Only consult agent.manifest.yaml when agent.yaml reported no
                // model env; otherwise we already default to `true`.
                if (!requiresModel) {
                    const manifestInfo = await fetchAgentManifestYaml(templatePath, commitSha);
                    if (manifestInfo?.hasModelResource) {
                        requiresModel = true;
                    }
                }

                templates.push({
                    language,
                    framework,
                    protocol,
                    displayName: '',
                    description: '',
                    path: templatePath,
                    requiresModel,
                });
            }
        }
    }

    return templates;
}

/**
 * Build the dimensions section from discovered templates and defaults.
 * Option order follows the insertion order of `DIMENSION_DEFAULTS[dim].options`
 * so we have UX control (e.g. promote `copilot-sdk` ahead of
 * `agent-framework`). Any id seen in the scanned templates but not declared in
 * the defaults is appended at the end in alphabetical order, so a new
 * framework added upstream does not break the build — just shows up last.
 *
 * @param {Array<{language: string, framework: string, protocol: string}>} templates
 */
function buildDimensions(templates) {
    /** @type {Record<string, {title: string, placeholder: string, options: Array<{id: string, displayName: string}>}>} */
    const dimensions = {};

    for (const dimKey of /** @type {const} */ (['language', 'framework', 'protocol'])) {
        const defaults = DIMENSION_DEFAULTS[dimKey];
        const seenIds = new Set(templates.map((t) => t[dimKey]));
        const declaredOrder = Object.keys(defaults.options);
        const orderedIds = [
            ...declaredOrder.filter((id) => seenIds.has(id)),
            ...[...seenIds].filter((id) => !declaredOrder.includes(id)).sort(),
        ];
        const options = orderedIds.map((id) => ({
            id,
            displayName: defaults.options[id] || id,
        }));
        dimensions[dimKey] = {
            title: defaults.title,
            placeholder: defaults.placeholder,
            options,
        };
    }

    return dimensions;
}

/**
 * Preserve existing displayName and description from the current catalog.
 * Only non-empty existing values are kept — never overwritten.
 * @param {Array<{displayName: string, description: string, path: string}>} templates
 */
function mergeExistingDisplayFields(templates) {
    if (!existsSync(OUTPUT_PATH)) {
        return;
    }

    try {
        const existing = JSON.parse(readFileSync(OUTPUT_PATH, 'utf-8'));
        /** @type {Map<string, {displayName?: string, description?: string}>} */
        const existingByPath = new Map();
        for (const t of existing.templates || []) {
            if (t.path) {
                existingByPath.set(t.path, t);
            }
        }

        const scannedPaths = new Set(templates.map((t) => t.path));
        for (const template of templates) {
            const prev = existingByPath.get(template.path);
            if (prev) {
                if (prev.displayName) {
                    template.displayName = prev.displayName;
                }
                if (prev.description) {
                    template.description = prev.description;
                }
            }
        }
        // Surface paths that exist in the prior catalog but were not produced
        // by this scan — upstream likely renamed or removed the sample, and any
        // PM-edited displayName/description on it has been dropped.
        for (const [path, prev] of existingByPath) {
            if (scannedPaths.has(path)) {
                continue;
            }
            const hadEdits = Boolean(prev.displayName || prev.description);
            const suffix = hadEdits ? ' Previously-edited displayName/description were dropped.' : '';
            warn(`Template "${path}" was in the previous catalog but no longer matches any scanned sample (upstream may have renamed or removed it).${suffix}`);
        }
    } catch (/** @type {any} */ err) {
        warn(`Could not read existing catalog at ${OUTPUT_PATH}: ${err.message}. Existing displayName/description values were NOT preserved this run.`);
    }
}

/**
 * Load source-controlled per-path overrides. Returns an empty map when the
 * file is missing or unreadable so generation never fails on it.
 *
 * @returns {Map<string, Record<string, unknown>>}
 */
function loadOverrides() {
    /** @type {Map<string, Record<string, unknown>>} */
    const byPath = new Map();
    if (!existsSync(OVERRIDES_PATH)) {
        return byPath;
    }
    try {
        const raw = JSON.parse(readFileSync(OVERRIDES_PATH, 'utf-8'));
        const entries = (raw && typeof raw === 'object' && raw.byPath) || {};
        for (const [path, fields] of Object.entries(entries)) {
            if (fields && typeof fields === 'object') {
                byPath.set(path, /** @type {Record<string, unknown>} */ (fields));
            }
        }
    } catch (/** @type {any} */ err) {
        warn(`Could not read sample-overrides.json: ${err.message}`);
    }
    return byPath;
}

/**
 * Shallow-merge per-path overrides onto scanned templates. Lets us correct
 * structural fields (e.g. `framework: "copilot-sdk"` for a sample that lives
 * under `bring-your-own/` upstream) without touching upstream or hand-editing
 * the generated catalog. Unknown override paths are logged but never fail
 * the build — upstream may have moved a sample.
 *
 * @param {Array<{path: string} & Record<string, unknown>>} templates
 * @param {Map<string, Record<string, unknown>>} overrides
 */
function applyOverrides(templates, overrides) {
    if (overrides.size === 0) {
        return;
    }
    /** @type {Set<string>} */
    const seenPaths = new Set();
    for (const template of templates) {
        seenPaths.add(template.path);
        const fields = overrides.get(template.path);
        if (fields) {
            Object.assign(template, fields);
        }
    }
    for (const path of overrides.keys()) {
        if (!seenPaths.has(path)) {
            warn(`Override for "${path}" did not match any scanned template; check sample-overrides.json (upstream may have moved or renamed the sample).`);
        }
    }
}

/**
 * Auto-fill empty displayName and description fields.
 *
 * displayName is ALWAYS derived from the template's directory name when empty
 * — the LLM is not consulted, because folder-name derivation is deterministic
 * and PM-predictable. Existing PM-curated displayName values are preserved by
 * the prior `mergeExistingDisplayFields` step, so this only affects newly
 * scanned templates.
 *
 * description is filled by the LLM (when configured) using the sample's
 * README as context. Without LLM credentials the description stays empty and
 * gets surfaced as an anomaly in the step summary.
 *
 * @param {Array<{displayName: string, description: string, path: string}>} templates
 * @param {string} commitSha
 */
async function autoFillDisplayFields(templates, commitSha) {
    // Fill displayName first — deterministic, no API calls.
    for (const template of templates) {
        if (!template.displayName) {
            template.displayName = displayNameFromPath(template.path);
        }
    }

    const needsDescription = templates.filter((t) => !t.description);
    if (needsDescription.length === 0) {
        console.log('All templates already have a description.');
    } else {
        const hasLLM = Boolean(AZURE_OPENAI_ENDPOINT && AZURE_OPENAI_API_KEY);
        if (hasLLM) {
            console.log(`Generating descriptions for ${needsDescription.length} templates using LLM...`);
            for (const template of needsDescription) {
                const readme = await fetchReadme(template.path, commitSha);
                if (!readme) {
                    continue;
                }
                const result = await generateWithLLM(readme, template.path);
                if (result?.description) {
                    template.description = result.description;
                }
            }
        } else {
            console.log(`${needsDescription.length} templates need a description but no LLM is configured; leaving empty (will be flagged as anomalies).`);
        }
    }

    // displayName always gets filled by the folder-name fallback above, so
    // anomaly detection here is description-only.
    for (const template of templates) {
        if (!template.description) {
            warn(`Template "${template.path}" is missing: description. PM should fill it before merge.`);
        }
    }
}

async function main() {
    const commitSha = parseCommitShaArg();
    console.log(`Using commit: ${commitSha}`);

    console.log('Scanning templates...');
    const templates = await scanTemplates(commitSha);
    console.log(`Found ${templates.length} templates`);

    // Step 1: Preserve existing PM-curated displayName/description values.
    mergeExistingDisplayFields(templates);

    // Step 2: Apply source-controlled per-path overrides (structural fields like
    // `framework` that the upstream tree layout cannot express on its own).
    applyOverrides(templates, loadOverrides());

    // Step 3: Fill remaining empties — displayName from folder name (always),
    // description from the LLM when configured.
    await autoFillDisplayFields(templates, commitSha);

    const dimensions = buildDimensions(templates);

    const catalog = {
        commitSha,
        repo: SAMPLES_REPO_URL,
        generatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
        dimensions,
        templateSelection: TEMPLATE_SELECTION,
        templates,
    };

    const outputDir = dirname(OUTPUT_PATH);
    mkdirSync(outputDir, { recursive: true });
    writeFileSync(OUTPUT_PATH, JSON.stringify(catalog, null, 4) + '\n', 'utf-8');

    console.log(`Wrote ${OUTPUT_PATH}`);

    writeSummary(templates.length);
}

/**
 * Append a Markdown report to `$GITHUB_STEP_SUMMARY` (when running in CI) that
 * surfaces the warnings collected during this run. Reviewers otherwise have
 * to scroll through raw job logs to notice anomalies like templates missing
 * descriptions or unmatched overrides. Locally (no env var) this is a no-op.
 *
 * @param {number} templateCount
 */
function writeSummary(templateCount) {
    const summaryPath = process.env.GITHUB_STEP_SUMMARY;
    if (!summaryPath) {
        if (warnings.length > 0) {
            console.warn(`\nCatalog generation produced ${warnings.length} warning(s) (see WARN lines above).`);
        }
        return;
    }

    const lines = [
        '',
        '## Sample Catalog Generation',
        '',
        `- Templates discovered: **${templateCount}**`,
        `- Warnings emitted: **${warnings.length}**`,
        '',
    ];

    if (warnings.length > 0) {
        lines.push('### ⚠ Anomalies');
        lines.push('');
        lines.push('These were logged during generation and may need human attention before merging:');
        lines.push('');
        for (const message of warnings) {
            lines.push(`- ${message}`);
        }
        lines.push('');
    } else {
        lines.push('No anomalies detected. ✅');
        lines.push('');
    }

    try {
        appendFileSync(summaryPath, lines.join('\n'), 'utf-8');
    } catch (/** @type {any} */ err) {
        console.warn(`Could not append to GITHUB_STEP_SUMMARY: ${err.message}`);
    }
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
