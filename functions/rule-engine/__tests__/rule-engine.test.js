'use strict';

const {
  evaluateRules,
  matchesRule,
  determineScenarios,
  isWithinEffectivePeriod
} = require('../rule-engine/index');

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const mockContext = {
  log: {
    info: () => {},
    verbose: () => {},
    warn: () => {},
    error: () => {}
  }
};

const sampleRules = [
  {
    id: 'rule-001',
    priority: 10,
    name: 'Ampla P1 CyberSecurity',
    enabled: true,
    effectiveFrom: null,
    effectiveTo: null,
    conditions: {
      product: 'Ampla',
      productFamily: null,
      areaPath: null,
      priority: 'P1',
      workItemType: null,
      isCyberSecurity: true,
      isHotfix: null
    },
    routing: {
      teamsChannelName: 'Security-Critical',
      teamsChannelWebhookUrl: 'https://example.webhook.office.com/1',
      emailGroup: 'security@company.com',
      escalationGroup: 'CISO-Team',
      securityLiaison: 'psirt@company.com',
      scenarios: ['A', 'B', 'C']
    }
  },
  {
    id: 'rule-002',
    priority: 20,
    name: 'Ampla P1 Non-Security',
    enabled: true,
    effectiveFrom: null,
    effectiveTo: null,
    conditions: {
      product: 'Ampla',
      productFamily: null,
      areaPath: null,
      priority: 'P1',
      workItemType: null,
      isCyberSecurity: false,
      isHotfix: null
    },
    routing: {
      teamsChannelName: 'Operations-Critical',
      teamsChannelWebhookUrl: 'https://example.webhook.office.com/2',
      emailGroup: 'ops@company.com',
      escalationGroup: 'Operations-Managers',
      securityLiaison: null,
      scenarios: ['A', 'B']
    }
  },
  {
    id: 'rule-999',
    priority: 999,
    name: 'Catch-All',
    enabled: true,
    effectiveFrom: null,
    effectiveTo: null,
    conditions: {
      product: 'Any',
      productFamily: null,
      areaPath: null,
      priority: 'Any',
      workItemType: null,
      isCyberSecurity: null,
      isHotfix: null
    },
    routing: {
      teamsChannelName: 'General-Support',
      teamsChannelWebhookUrl: 'https://example.webhook.office.com/999',
      emailGroup: 'support@company.com',
      escalationGroup: null,
      securityLiaison: null,
      scenarios: ['A']
    }
  }
];

// ---------------------------------------------------------------------------
// matchesRule tests
// ---------------------------------------------------------------------------

describe('matchesRule', () => {
  test('matches exact product and priority with cyber flag', () => {
    const workItem = {
      product: 'Ampla', priority: '1', isCyberSecurity: true,
      productFamily: '', areaPath: '', workItemType: 'Bug', isHotfix: false
    };
    expect(matchesRule(sampleRules[0], workItem)).toBe(true);
  });

  test('does not match wrong cyber flag', () => {
    const workItem = {
      product: 'Ampla', priority: '1', isCyberSecurity: false,
      productFamily: '', areaPath: '', workItemType: 'Bug', isHotfix: false
    };
    expect(matchesRule(sampleRules[0], workItem)).toBe(false);
  });

  test('matches P1 as string "P1"', () => {
    const workItem = {
      product: 'Ampla', priority: 'P1', isCyberSecurity: false,
      productFamily: '', areaPath: '', workItemType: 'Bug', isHotfix: false
    };
    expect(matchesRule(sampleRules[1], workItem)).toBe(true);
  });

  test('catch-all rule matches any product', () => {
    const workItem = {
      product: 'SomeNewProduct', priority: '3', isCyberSecurity: false,
      productFamily: '', areaPath: '', workItemType: 'Feature', isHotfix: false
    };
    expect(matchesRule(sampleRules[2], workItem)).toBe(true);
  });

  test('product match is case-insensitive', () => {
    const workItem = {
      product: 'ampla', priority: '1', isCyberSecurity: true,
      productFamily: '', areaPath: '', workItemType: 'Bug', isHotfix: false
    };
    expect(matchesRule(sampleRules[0], workItem)).toBe(true);
  });

  test('area path uses substring match', () => {
    const rule = {
      ...sampleRules[0],
      conditions: { ...sampleRules[0].conditions, areaPath: 'Security' }
    };
    const workItem = {
      product: 'Ampla', priority: '1', isCyberSecurity: true,
      productFamily: '', areaPath: 'MyProject\\Ampla\\Security\\Backend',
      workItemType: 'Bug', isHotfix: false
    };
    expect(matchesRule(rule, workItem)).toBe(true);
  });

  test('disabled rule should not be evaluated directly via matchesRule', () => {
    // matchesRule itself does not check enabled; evaluateRules filters disabled rules
    const disabledRule = { ...sampleRules[0], enabled: false };
    const workItem = {
      product: 'Ampla', priority: '1', isCyberSecurity: true,
      productFamily: '', areaPath: '', workItemType: 'Bug', isHotfix: false
    };
    // matchesRule will still return true — the filter happens in evaluateRules
    expect(matchesRule(disabledRule, workItem)).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// determineScenarios tests
// ---------------------------------------------------------------------------

describe('determineScenarios', () => {
  test('always includes scenario A', () => {
    const workItem = { priority: '4', isCyberSecurity: false };
    expect(determineScenarios(workItem)).toContain('A');
  });

  test('P1 adds scenario B', () => {
    const workItem = { priority: '1', isCyberSecurity: false };
    expect(determineScenarios(workItem)).toContain('B');
  });

  test('P1 as "P1" adds scenario B', () => {
    const workItem = { priority: 'P1', isCyberSecurity: false };
    expect(determineScenarios(workItem)).toContain('B');
  });

  test('P2 does not add scenario B', () => {
    const workItem = { priority: '2', isCyberSecurity: false };
    expect(determineScenarios(workItem)).not.toContain('B');
  });

  test('isCyberSecurity=true adds scenario C', () => {
    const workItem = { priority: '3', isCyberSecurity: true };
    expect(determineScenarios(workItem)).toContain('C');
  });

  test('isCyberSecurity=false does not add scenario C', () => {
    const workItem = { priority: '3', isCyberSecurity: false };
    expect(determineScenarios(workItem)).not.toContain('C');
  });

  test('P1 CyberSecurity gives all scenarios A, B, C', () => {
    const workItem = { priority: '1', isCyberSecurity: true };
    const scenarios = determineScenarios(workItem);
    expect(scenarios).toEqual(expect.arrayContaining(['A', 'B', 'C']));
    expect(scenarios).toHaveLength(3);
  });
});

// ---------------------------------------------------------------------------
// evaluateRules tests
// ---------------------------------------------------------------------------

describe('evaluateRules', () => {
  test('returns only matched rules sorted by priority', () => {
    const workItem = {
      workItemId: 123, product: 'Ampla', priority: '1',
      isCyberSecurity: true, productFamily: '', areaPath: '',
      workItemType: 'Bug', isHotfix: false
    };
    const result = evaluateRules(workItem, sampleRules, mockContext, 'test-001');
    // rule-001 (P1+cyber), rule-999 (catch-all) — NOT rule-002 (cyber=false)
    expect(result.matchedRuleCount).toBe(2);
    expect(result.routingDecisions[0].ruleId).toBe('rule-001');
    expect(result.routingDecisions[1].ruleId).toBe('rule-999');
  });

  test('filters out disabled rules', () => {
    const rulesWithDisabled = [
      { ...sampleRules[0], enabled: false },
      sampleRules[2]
    ];
    const workItem = {
      workItemId: 456, product: 'Ampla', priority: '1',
      isCyberSecurity: true, productFamily: '', areaPath: '',
      workItemType: 'Bug', isHotfix: false
    };
    const result = evaluateRules(workItem, rulesWithDisabled, mockContext, 'test-002');
    expect(result.matchedRuleCount).toBe(1);
    expect(result.routingDecisions[0].ruleId).toBe('rule-999');
  });

  test('unknown product matches only catch-all', () => {
    const workItem = {
      workItemId: 789, product: 'FactorySuite', priority: '3',
      isCyberSecurity: false, productFamily: '', areaPath: '',
      workItemType: 'Feature', isHotfix: false
    };
    const result = evaluateRules(workItem, sampleRules, mockContext, 'test-003');
    expect(result.matchedRuleCount).toBe(1);
    expect(result.routingDecisions[0].ruleId).toBe('rule-999');
  });

  test('includes correct scenarios in result', () => {
    const workItem = {
      workItemId: 321, product: 'Ampla', priority: '1',
      isCyberSecurity: true, productFamily: '', areaPath: '',
      workItemType: 'Bug', isHotfix: false
    };
    const result = evaluateRules(workItem, sampleRules, mockContext, 'test-004');
    expect(result.scenarios).toEqual(expect.arrayContaining(['A', 'B', 'C']));
  });
});

// ---------------------------------------------------------------------------
// isWithinEffectivePeriod tests
// ---------------------------------------------------------------------------

describe('isWithinEffectivePeriod', () => {
  test('null dates = always effective', () => {
    expect(isWithinEffectivePeriod({ effectiveFrom: null, effectiveTo: null })).toBe(true);
  });

  test('future effectiveFrom = not yet effective', () => {
    const future = new Date(Date.now() + 86400000).toISOString();
    expect(isWithinEffectivePeriod({ effectiveFrom: future, effectiveTo: null })).toBe(false);
  });

  test('past effectiveTo = expired', () => {
    const past = new Date(Date.now() - 86400000).toISOString();
    expect(isWithinEffectivePeriod({ effectiveFrom: null, effectiveTo: past })).toBe(false);
  });

  test('current period = effective', () => {
    const past   = new Date(Date.now() - 86400000).toISOString();
    const future = new Date(Date.now() + 86400000).toISOString();
    expect(isWithinEffectivePeriod({ effectiveFrom: past, effectiveTo: future })).toBe(true);
  });
});
