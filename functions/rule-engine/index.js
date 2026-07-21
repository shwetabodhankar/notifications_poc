'use strict';

const { BlobServiceClient } = require('@azure/storage-blob');
const { DefaultAzureCredential } = require('@azure/identity');
const Ajv = require('ajv');
const addFormats = require('ajv-formats');

// In-memory rules cache — avoids redundant Blob reads for every invocation
let rulesCache = null;
let rulesCacheTime = null;
const CACHE_TTL_MS = 5 * 60 * 1000; // 5 minutes

/**
 * Azure Function v4 HTTP trigger — Rule Engine
 *
 * Receives a normalised work item payload from the Orchestrator Logic App,
 * loads routing rules from Azure Blob Storage, evaluates each enabled rule
 * against the work item fields, and returns the set of matched rules with
 * their routing decisions and determined notification scenarios.
 */
module.exports = async function (context, req) {
  const correlationId = req.headers['x-correlation-id'] || `local-${Date.now()}`;
  context.log.info(`[${correlationId}] Rule engine invoked`);

  if (req.method !== 'POST') {
    return sendResponse(context, 405, { error: 'Method Not Allowed' });
  }

  const workItem = req.body;
  if (!workItem || !workItem.workItemId) {
    context.log.warn(`[${correlationId}] Invalid request body — missing workItemId`);
    return sendResponse(context, 400, {
      error: 'Invalid request body: workItemId is required',
      correlationId
    });
  }

  try {
    const rules = await getRoutingRules(context, correlationId);
    const result = evaluateRules(workItem, rules, context, correlationId);

    context.log.info(
      `[${correlationId}] Evaluation complete — ${result.matchedRuleCount} rule(s) matched`
    );

    return sendResponse(context, 200, result);
  } catch (error) {
    context.log.error(`[${correlationId}] Rule engine error: ${error.message}`, error.stack);
    return sendResponse(context, 500, {
      error: 'Rule evaluation failed',
      message: error.message,
      correlationId
    });
  }
};

// ---------------------------------------------------------------------------
// Rule Loading
// ---------------------------------------------------------------------------

/**
 * Loads routing rules from Azure Blob Storage with an in-memory cache.
 * Supports both connection string and Managed Identity authentication.
 */
async function getRoutingRules(context, correlationId) {
  const now = Date.now();
  if (rulesCache && rulesCacheTime && now - rulesCacheTime < CACHE_TTL_MS) {
    context.log.verbose(`[${correlationId}] Using cached rules (age: ${Math.round((now - rulesCacheTime) / 1000)}s)`);
    return rulesCache;
  }

  context.log.info(`[${correlationId}] Loading rules from Blob Storage`);
  const rulesJson = await downloadRulesBlob(context);

  // Parse and validate
  const parsed = JSON.parse(rulesJson);
  validateRulesSchema(parsed);

  rulesCache = parsed.rules;
  rulesCacheTime = now;
  context.log.info(`[${correlationId}] Loaded ${rulesCache.length} rules (version: ${parsed.version})`);
  return rulesCache;
}

async function downloadRulesBlob(context) {
  const containerName = process.env.RULES_CONTAINER_NAME || 'routing-rules';
  const blobName = process.env.RULES_BLOB_NAME || 'routing-rules.json';

  let blobServiceClient;

  if (process.env.STORAGE_CONNECTION_STRING) {
    // Local development / explicit connection string
    blobServiceClient = BlobServiceClient.fromConnectionString(
      process.env.STORAGE_CONNECTION_STRING
    );
  } else {
    // Production: Managed Identity (system-assigned)
    const accountName = process.env.STORAGE_ACCOUNT_NAME;
    if (!accountName) {
      throw new Error('STORAGE_ACCOUNT_NAME environment variable is required when not using a connection string');
    }
    const credential = new DefaultAzureCredential();
    blobServiceClient = new BlobServiceClient(
      `https://${accountName}.blob.core.windows.net`,
      credential
    );
  }

  const containerClient = blobServiceClient.getContainerClient(containerName);
  const blobClient = containerClient.getBlobClient(blobName);

  const downloadResponse = await blobClient.download(0);
  return streamToString(downloadResponse.readableStreamBody);
}

async function streamToString(readableStream) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    readableStream.on('data', (chunk) => chunks.push(Buffer.isBuffer(chunk) ? chunk.toString('utf-8') : chunk));
    readableStream.on('end', () => resolve(chunks.join('')));
    readableStream.on('error', reject);
  });
}

function validateRulesSchema(parsed) {
  if (!parsed || !Array.isArray(parsed.rules)) {
    throw new Error('routing-rules.json must have a top-level "rules" array');
  }
  if (!parsed.version) {
    throw new Error('routing-rules.json must have a "version" field');
  }
}

// ---------------------------------------------------------------------------
// Rule Evaluation
// ---------------------------------------------------------------------------

/**
 * Evaluates all enabled rules against the work item and returns matched rules,
 * routing decisions, and applicable notification scenarios.
 */
function evaluateRules(workItem, rules, context, correlationId) {
  // Filter disabled rules and sort by priority ascending (lower = evaluated first)
  const enabledRules = rules
    .filter((r) => r.enabled !== false)
    .filter((r) => isWithinEffectivePeriod(r))
    .sort((a, b) => (a.priority || 999) - (b.priority || 999));

  context.log.verbose(`[${correlationId}] Evaluating ${enabledRules.length} enabled rules`);

  const matchedRules = enabledRules.filter((rule) => {
    const matched = matchesRule(rule, workItem);
    if (matched) {
      context.log.info(`[${correlationId}] Rule matched: [${rule.id}] ${rule.name}`);
    }
    return matched;
  });

  const scenarios = determineScenarios(workItem);

  return {
    correlationId,
    workItemId: workItem.workItemId,
    matchedRuleCount: matchedRules.length,
    routingDecisions: matchedRules.map((rule) => ({
      ruleId: rule.id,
      ruleName: rule.name,
      routing: rule.routing
    })),
    scenarios
  };
}

/**
 * Returns true if the current UTC time falls within the rule's effective period.
 */
function isWithinEffectivePeriod(rule) {
  const now = new Date();
  if (rule.effectiveFrom && new Date(rule.effectiveFrom) > now) return false;
  if (rule.effectiveTo && new Date(rule.effectiveTo) < now) return false;
  return true;
}

/**
 * Evaluates all conditions on a single rule against the work item fields.
 * All conditions must match (AND logic). Null / 'Any' / '*' are wildcards.
 */
function matchesRule(rule, workItem) {
  const c = rule.conditions;
  if (!c) return false;

  return (
    matchField(c.product, workItem.product) &&
    matchField(c.productFamily, workItem.productFamily) &&
    matchAreaPath(c.areaPath, workItem.areaPath) &&
    matchPriority(c.priority, workItem.priority) &&
    matchField(c.workItemType, workItem.workItemType) &&
    matchBoolean(c.isCyberSecurity, workItem.isCyberSecurity) &&
    matchBoolean(c.isHotfix, workItem.isHotfix)
  );
}

/** Case-insensitive equality match. Null / 'Any' / '*' are wildcards. */
function matchField(ruleValue, actualValue) {
  if (isWildcard(ruleValue)) return true;
  if (actualValue === null || actualValue === undefined || actualValue === '') return false;
  return ruleValue.toLowerCase() === actualValue.toString().toLowerCase();
}

/** Case-insensitive substring match on area path. */
function matchAreaPath(ruleAreaPath, actualAreaPath) {
  if (isWildcard(ruleAreaPath)) return true;
  if (!actualAreaPath) return false;
  return actualAreaPath.toLowerCase().includes(ruleAreaPath.toLowerCase());
}

/**
 * Priority matching: normalises 'P1' and '1' to the same value.
 * Rule priority 'P1' matches work item priority '1' and vice versa.
 */
function matchPriority(rulePriority, actualPriority) {
  if (isWildcard(rulePriority)) return true;
  if (actualPriority === null || actualPriority === undefined) return false;
  const normalise = (v) => v.toString().replace(/^P/i, '');
  return normalise(rulePriority) === normalise(actualPriority.toString());
}

/** Strict boolean match. Null means "match any value". */
function matchBoolean(ruleValue, actualValue) {
  if (ruleValue === null || ruleValue === undefined) return true;
  // Coerce string 'true'/'false' from Logic App expressions
  const coerce = (v) => {
    if (typeof v === 'boolean') return v;
    if (typeof v === 'string') return v.toLowerCase() === 'true';
    return Boolean(v);
  };
  return coerce(ruleValue) === coerce(actualValue);
}

function isWildcard(value) {
  return value === null || value === undefined || value === 'Any' || value === '*' || value === '';
}

// ---------------------------------------------------------------------------
// Scenario Determination
// ---------------------------------------------------------------------------

/**
 * Determines which notification scenarios apply to the work item.
 *
 * Scenario A — Standard routing (always)
 * Scenario B — Critical escalation (priority P1)
 * Scenario C — Cyber security escalation (isCyberSecurity = true)
 */
function determineScenarios(workItem) {
  const scenarios = ['A'];

  const priority = workItem.priority ? workItem.priority.toString().replace(/^P/i, '') : '4';
  if (priority === '1') {
    scenarios.push('B');
  }

  const isCyberSecurity =
    workItem.isCyberSecurity === true ||
    workItem.isCyberSecurity === 'true';
  if (isCyberSecurity) {
    scenarios.push('C');
  }

  return scenarios;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function sendResponse(context, statusCode, body) {
  context.res = {
    status: statusCode,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  };
}

// Export for unit testing
module.exports.evaluateRules = evaluateRules;
module.exports.matchesRule = matchesRule;
module.exports.determineScenarios = determineScenarios;
module.exports.isWithinEffectivePeriod = isWithinEffectivePeriod;
