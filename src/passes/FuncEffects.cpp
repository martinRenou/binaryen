/*
 * Copyright 2021 WebAssembly Community Group participants
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//
// Operations on Stack IR.
//

#include "ir/module-utils.h"
#include "pass.h"
#include "wasm.h"

namespace wasm {

// Generate Stack IR from Binaryen IR

struct GenerateFuncEffects
  : public WalkerPass<PostWalker<GenerateFuncEffects>> {
  virtual void run(PassRunner* runner, Module* module) {
    // First, clear any previous function effects. We don't want to notice them
    // when we compute effects here.
    auto& funcEffects = runner->options.funcEffects;
    funcEffects.clear();

    // Create a single Info to represent "anything" - any effect might happen,
    // and we give up on trying to analyze things. To represent that, scan a
    // fake call (running the actual effect analyzer code on a call is important
    // so that it picks up things like possibly throwing if exceptions are
    // enabled, etc.). Note that this
    // does not say anything about effects on locals on the stack, which is
    // intentional - we will use this as the effects of a call, which indeed
    // cannot have such effects.
    Call fakeCall(module->allocator);
    std::shared_ptr<EffectAnalyzer> anything =
      std::make_shared<EffectAnalyzer>(runner->options, *module, &fakeCall);

    struct Info
      : public ModuleUtils::CallGraphPropertyAnalysis<Info>::FunctionInfo {
      std::shared_ptr<EffectAnalyzer> effects;
    };
    ModuleUtils::CallGraphPropertyAnalysis<Info> analyzer(
      *module, [&](Function* func, Info& info) {
        if (func->imported()) {
          // Imported functions can do anything.
          info.effects = anything;
        } else {
          // For defined functions, compute the effects in their body.
          info.effects = std::make_shared<EffectAnalyzer>(
            runner->options, *module, func->body);
          auto& effects = *info.effects;

          // Discard calls, as we will propagate their effects below.
          effects.calls = false;

          // Discard any effects on locals, since those are not noticeable in
          // the caller.
          effects.localsWritten.clear();
          effects.localsRead.clear();

          // Discard branching out of an expression or a return - we are
          // returning back out to the caller anyhow. (If this is a return_call
          // then we do need this property, but it will be added when computing
          // effects: visitCall() in effects.h will add our effects as computed
          // here, and then also take into account return_call effects as well.)
          effects.branchesOut = false;

          // As we have parsed an entire function, there should be no structural
          // info about being inside a try-catch.
          assert(!effects.tryDepth);
          assert(!effects.catchDepth);
          assert(!effects.danglingPop);
        }
      });

    // Assume a non-direct call might throw.
    analyzer.propagateBack(
      [&](const Info& funcInfo, Info& callerInfo) {
        if (callerInfo.effects == anything) {
          // This is already the worst case, stop.
          return false;
        }

        auto old = *callerInfo.effects;
        callerInfo.effects->mergeIn(*funcInfo.effects);
        return (*callerInfo.effects) != old;
      },
      [&](Info& info) {
        // Assume the worst, as there are indirect calls here or something else
        // that the analzer cannot analyze.
        info.effects = anything;
      });

    // TODO Recursion is an effect... of sorts. We can run out of call stack
    //      and error. So we must detect that and mark functions as "may recurse".

    // TODO: increase the Cost of calls? Now without side effects we may be
    //       tempted to selectify etc. and do more calls as a result.

    // TODO: share the Info object between functions where possible to save
    //       memory, like we do with |anything| already. E.g. if a function's
    //       final result is similar to a function it calls (common case), share

    // Copy the info to the final location.
    for (auto& [func, info] : analyzer.map) {
      funcEffects[func->name] = info.effects;
    }
  }
};

struct DiscardFuncEffects : public Pass {
  virtual void run(PassRunner* runner, Module* module) {
    runner->options.funcEffects.clear();
  }
};

Pass* createGenerateFuncEffectsPass() { return new GenerateFuncEffects(); }

Pass* createDiscardFuncEffectsPass() { return new DiscardFuncEffects(); }

} // namespace wasm