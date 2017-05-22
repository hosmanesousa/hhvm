/*
   +----------------------------------------------------------------------+
   | HipHop for PHP                                                       |
   +----------------------------------------------------------------------+
   | Copyright (c) 2010-present Facebook, Inc. (http://www.facebook.com)  |
   +----------------------------------------------------------------------+
   | This source file is subject to version 3.01 of the PHP license,      |
   | that is bundled with this package in the file LICENSE, and is        |
   | available through the world-wide-web at the following url:           |
   | http://www.php.net/license/3_01.txt                                  |
   | If you did not receive a copy of the PHP license and are unable to   |
   | obtain it through the world-wide-web, please send a note to          |
   | license@php.net so we can mail you a copy immediately.               |
   +----------------------------------------------------------------------+
*/

#include "hphp/runtime/vm/jit/vasm-simplify-internal.h"

#include "hphp/runtime/vm/jit/vasm.h"
#include "hphp/runtime/vm/jit/vasm-gen.h"
#include "hphp/runtime/vm/jit/vasm-instr.h"
#include "hphp/runtime/vm/jit/vasm-unit.h"
#include "hphp/runtime/vm/jit/vasm-util.h"

namespace HPHP { namespace jit { namespace arm {

namespace {

///////////////////////////////////////////////////////////////////////////////

template<typename Inst>
bool simplify(Env&, const Inst& inst, Vlabel b, size_t i) { return false; }

///////////////////////////////////////////////////////////////////////////////

bool simplify(Env& env, const loadb& inst, Vlabel b, size_t i) {
  return if_inst<Vinstr::movzbl>(env, b, i + 1, [&] (const movzbl& mov) {
    // loadb{s, tmp}; movzbl{tmp, d}; -> loadzbl{s, d};
    if (!(env.use_counts[inst.d] == 1 &&
          inst.d == mov.s)) return false;

    return simplify_impl(env, b, i, [&] (Vout& v) {
      v << loadzbl{inst.s, mov.d};
      return 2;
    });
  });
}

///////////////////////////////////////////////////////////////////////////////

bool simplify(Env& env, const movzbl& inst, Vlabel b, size_t i) {
  // movzbl{s, d}; shrli{2, s, d} --> ubfmli{2, 7, s, d}
  return if_inst<Vinstr::shrli>(env, b, i + 1, [&](const shrli& sh) {
    if (!(sh.s0.l() == 2 &&
      env.use_counts[inst.d] == 1 &&
      env.use_counts[sh.sf] == 0 &&
      inst.d == sh.s1)) return false;

    return simplify_impl(env, b, i, [&] (Vout& v) {
      v << copy{inst.s, inst.d};
      v << ubfmli{2, 7, inst.d, sh.d};
      return 2;
    });
  });
}

///////////////////////////////////////////////////////////////////////////////

}

bool simplify(Env& env, Vlabel b, size_t i) {
  assertx(i <= env.unit.blocks[b].code.size());
  auto const& inst = env.unit.blocks[b].code[i];

  switch (inst.op) {
#define O(name, ...)    \
    case Vinstr::name:  \
      return simplify(env, inst.name##_, b, i); \

    VASM_OPCODES
#undef O
  }
  not_reached();
}

///////////////////////////////////////////////////////////////////////////////

}}}