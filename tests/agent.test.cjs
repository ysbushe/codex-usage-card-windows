'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {formatRateLimits, resolveCodexBin, createWindowsEndpointVerifier} = require('../plugins/usage-card-windows/runtime/agent.cjs');

test('weekly-only accounts show valid remaining usage', () => {
  for (const planType of ['team','business','enterprise','pro']) {
    const data = {rateLimits:{planType,primary:{windowDurationMins:10080,usedPercent:25}}};
    assert.equal(formatRateLimits(data).percent,75,planType);
    assert.equal(formatRateLimits(data).windowLabel,'周');
  }
});

test('missing reset count falls back to available cards', () => {
  const data={rateLimits:{planType:'plus',primary:{windowDurationMins:300,usedPercent:10}},rateLimitResetCredits:{availableCount:null,credits:[{status:'available',resetType:'codexRateLimits'}]}};
  assert.match(formatRateLimits(data).title,/重置卡：1 张可用/);
  assert.doesNotMatch(formatRateLimits({rateLimits:data.rateLimits}).title,/重置卡/);
});

test('bundled CLI precedes managed fallback', () => {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'usage-card-test-'));
  const previous=process.env.LOCALAPPDATA;
  const appRoot=path.join(root,'app'); const resources=path.join(appRoot,'resources');
  const parent=path.join(root,'OpenAI');const codex=path.join(parent,'Codex');const bin=path.join(codex,'bin');const version=path.join(bin,'old');
  const bundled=path.join(resources,'codex.exe');const managed=path.join(version,'codex.exe');
  try {
    process.env.LOCALAPPDATA=root;
    fs.mkdirSync(resources,{recursive:true});fs.mkdirSync(version,{recursive:true});
    fs.writeFileSync(bundled,'');fs.writeFileSync(managed,'');
    assert.equal(resolveCodexBin('codex',path.join(appRoot,'ChatGPT.exe'),'win32'),bundled);
    fs.unlinkSync(bundled);
    assert.equal(resolveCodexBin('codex',path.join(appRoot,'ChatGPT.exe'),'win32'),managed);
  } finally {
    if(previous===undefined) delete process.env.LOCALAPPDATA; else process.env.LOCALAPPDATA=previous;
    for (const f of [bundled,managed]) if (fs.existsSync(f)) fs.unlinkSync(f);
    for (const d of [resources,appRoot,version,bin,codex,parent,root]) if (fs.existsSync(d)) fs.rmdirSync(d);
  }
});

test('endpoint verifier rejects absent PID, failed check and PID reuse', async () => {
  assert.throws(()=>createWindowsEndpointVerifier({expectedPid:null,appPath:process.execPath}),/expected-pid/);
  let ticks='111';
  const execFile=(file,args,options,callback)=>setImmediate(()=>callback(null,ticks,''));
  const verify=createWindowsEndpointVerifier({expectedPid:123,appPath:process.execPath,execFile});
  await verify(); ticks='222'; await assert.rejects(verify(),/进程已变化/);
  const failed=createWindowsEndpointVerifier({expectedPid:123,appPath:process.execPath,execFile:(f,a,o,cb)=>setImmediate(()=>cb(Error('failed'),'',''))});
  await assert.rejects(failed(),/无法核验/);
});
