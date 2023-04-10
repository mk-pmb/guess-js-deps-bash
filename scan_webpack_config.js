'use strict';

// const same = require('assert').deepStrictEqual;

function orf(x) { return x || false; }
function shellQuoteNoApos(s) { return "'" + s.replace(/'/g, '') + "'"; }

function setSlotNoApos(k, v, op) {
  console.log("RESOLVE_CACHE['" + k + "']" + (op || '') + '='
    + shellQuoteNoApos(v));
}


const EX = function scanWebpackConfig(wpCfg) {
  const scan = {
    wpCfg,
    needPkgs: new Set(EX.alwaysNeededPkgs),
  };
  EX.aliases(scan);
  EX.resourceLoaders(scan);

  setSlotNoApos('?bundler://webpack/config/needs',
    Array.from(scan.needPkgs.values()).sort().join(' '));
};


Object.assign(EX, {

  alwaysNeededPkgs: [
    'browserslist',
  ],


  aliases(scan) {
    const alNames = Object.keys(orf(orf(scan.wpCfg.resolve).alias)).join(' ');
    if (!alNames) { return; }
    setSlotNoApos('?bundler://alias_pkgnames', (' ' + alNames + ' '), '+');
  },


  resourceLoaders(scan) {
    [].concat(orf(scan.wpCfg.module).rules).forEach(function foundRule(rule) {
      if (!rule) { return; }
      const ldr = (rule.loader || orf(rule.use).loader);
      if (!ldr) { return; }
      scan.needPkgs.add(ldr);
    });
  },


});

module.exports = EX;
