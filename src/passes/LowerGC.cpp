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
// Lowers Wasm GC to linear memory.
//
// Layouts:
//   Struct:
//     u32 rtt
//     fields...
//   Array:
//     u32 rtt
//     u32 size
//     fields...
//

#include "ir/module-utils.h"
#include "pass.h"
#include "wasm-builder.h"
#include "wasm.h"

namespace wasm {

namespace {

Type getLoweredType(Type type, Memory& memory) {
  // References and Rtts are pointers.
  if (type.isRef() || type.isRtt()) {
    return memory.indexType;
  }
  return type;
}

// The layout of a struct in linear memory.
struct Layout {
  // The total size of the struct.
  Address size;
  // The offsets of fields. Note that the first field's offset may not be 0,
  // as we need room for the rtt.
  SmallVector<Address, 4> fieldOffsets;
};

using Layouts = std::unordered_map<HeapType, Layout>;

struct LoweringInfo {
  Layouts layouts;

  Name malloc;

  Address pointerSize;
  Type pointerType;
};

// Lower GC instructions. Most turn into function calls, and we rely on inlining
// and other optimizations to improve the code.
struct LowerGCCode
  : public WalkerPass<
      PostWalker<LowerGCCode, UnifiedExpressionVisitor<LowerGCCode>>> {
  bool isFunctionParallel() override { return true; }

  LoweringInfo* loweringInfo;

  using Parent =
    WalkerPass<PostWalker<LowerGCCode, UnifiedExpressionVisitor<LowerGCCode>>>;

  LowerGCCode* create() override { return new LowerGCCode(loweringInfo); }

  LowerGCCode(LoweringInfo* loweringInfo) : loweringInfo(loweringInfo) {}

  void visitExpression(Expression* curr) {
    // Update the type. This helps things like local.get, control flow
    // structures, etc.
    curr->type = lower(curr->type);
  }

  void visitRefNull(RefNull* curr) {
    replaceCurrent(LiteralUtils::makeZero(lower(curr->type), *getModule()));
  }

  void visitStructNew(StructNew* curr) {
    auto type = relevantHeapTypes[curr];
    std::vector<Expression*> operands;
    std::string name = getExpressionName(curr);
    if (curr->isWithDefault()) {
      name += "WithDefault";
    } else {
      for (auto* operand : curr->operands) {
        operands.push_back(operand);
      }
    }
    operands.push_back(curr->rtt);
    name += std::string("$") + getModule()->typeNames[type].name.str;
    Builder builder(*getModule());
    replaceCurrent(builder.makeCall(name, operands, loweringInfo->pointerType));
  }

  void visitStructSet(StructSet* curr) {
    Builder builder(*getModule());
    auto type = relevantHeapTypes[curr];
    auto name = std::string("StructSet$") +
                getModule()->typeNames[type].name.str + '$' +
                std::to_string(curr->index);
    replaceCurrent(
      builder.makeCall(name, {curr->ref, curr->value}, Type::none));
  }

  void visitStructGet(StructGet* curr) {
    Builder builder(*getModule());
    auto type = relevantHeapTypes[curr];
    auto name = std::string("StructGet$") +
                getModule()->typeNames[type].name.str + '$' +
                std::to_string(curr->index);
    replaceCurrent(builder.makeCall(
      name, {curr->ref}, getLoweredType(curr->type, getModule()->memory)));
  }

  void visitArrayNew(ArrayNew* curr) {
    auto type = relevantHeapTypes[curr];
    std::vector<Expression*> operands;
    std::string name = getExpressionName(curr);
    if (curr->isWithDefault()) {
      name += "WithDefault";
    } else {
      operands.push_back(curr->init);
    }
    operands.push_back(curr->size);
    operands.push_back(curr->rtt);
    name += std::string("$") + getModule()->typeNames[type].name.str;
    Builder builder(*getModule());
    replaceCurrent(builder.makeCall(name, operands, loweringInfo->pointerType));
  }

  void visitArraySet(ArraySet* curr) {
    Builder builder(*getModule());
    auto type = relevantHeapTypes[curr];
    auto name = std::string("ArraySet$") +
                getModule()->typeNames[type].name.str;
    replaceCurrent(
      builder.makeCall(name, {curr->ref, curr->index, curr->value}, Type::none));
  }

  void visitArrayGet(ArrayGet* curr) {
    Builder builder(*getModule());
    auto type = relevantHeapTypes[curr];
    auto name = std::string("ArrayGet$") +
                getModule()->typeNames[type].name.str;
    auto element = type.getArray().element;
    auto loweredType = getLoweredType(element.type, getModule()->memory);
    replaceCurrent(builder.makeCall(
      name, {curr->ref, curr->index}, loweredType));
  }

  void visitRttCanon(RttCanon* curr) {
    // FIXME actual rtt allocations and values
    replaceCurrent(LiteralUtils::makeZero(lower(curr->type), *getModule()));
  }

  void doWalkFunction(Function* func) {
    // Lower the types on the function itself.
    std::vector<Type> params;
    for (auto t : func->sig.params) {
      params.push_back(lower(t));
    }
    std::vector<Type> results;
    for (auto t : func->sig.results) {
      results.push_back(lower(t));
    }
    func->sig = Signature(Type(params), Type(results));
    for (auto& t : func->vars) {
      t = lower(t);
    }

    // Scan the function for types we will need later. We cannot do this in a
    // single pass, as we cannot e.g. lower the rtt a struct operation receives
    // before we process the struct (if we did, the struct would not receive the
    // heap type, and we would not know what to lower).
    struct Scanner : public PostWalker<Scanner> {
      std::unordered_map<Expression*, HeapType> relevantHeapTypes;

      void visitStructNew(StructNew* curr) {
        relevantHeapTypes[curr] = curr->rtt->type.getHeapType();
      }
      void visitStructGet(StructGet* curr) {
        relevantHeapTypes[curr] = curr->ref->type.getHeapType();
      }
      void visitStructSet(StructSet* curr) {
        relevantHeapTypes[curr] = curr->ref->type.getHeapType();
      }

      void visitArrayNew(ArrayNew* curr) {
        relevantHeapTypes[curr] = curr->rtt->type.getHeapType();
      }
      void visitArrayGet(ArrayGet* curr) {
        relevantHeapTypes[curr] = curr->ref->type.getHeapType();
      }
      void visitArraySet(ArraySet* curr) {
        relevantHeapTypes[curr] = curr->ref->type.getHeapType();
      }
    } scanner;
    scanner.walk(func->body);
    relevantHeapTypes = std::move(scanner.relevantHeapTypes);

    // Lower all the code.
    Parent::doWalkFunction(func);

    // Ensure unique names for the loops that we created.
    UniqueNameMapper::uniquify(func->body);
  }

private:
  std::unordered_map<Expression*, HeapType> relevantHeapTypes;

  Type lower(Type type) { return getLoweredType(type, getModule()->memory); }
};

} // anonymous namespace

struct LowerGC : public Pass {
  void run(PassRunner* runner, Module* module_) override {
    // First, ensure types have names, as we use the names when creating the
    // runtime code.
    {
      PassRunner subRunner(runner);
      subRunner.add("name-types");
      subRunner.add("dce");
      subRunner.setIsNested(true);
      subRunner.run();
    }
    module = module_;
    std::cout << "add mem\n";
    addMemory();
    std::cout << "add run\n";
    addRuntime();
    std::cout << "comp layouts\n";
    computeStructLayouts();
    std::cout << "lower code\n";
    lowerCode(runner);
  }

private:
  Module* module;

  LoweringInfo loweringInfo;

  void addMemory() {
    module->memory.exists = true;

    // 16MB, arbitrarily for now.
    module->memory.initial = module->memory.max = 256;

    assert(!module->memory.is64());
    loweringInfo.pointerSize = 4;
    loweringInfo.pointerType = module->memory.indexType;
  }

  void addRuntime() {
    Builder builder(*module);
    auto* nextMalloc =
      module->addGlobal(builder.makeGlobal("nextMalloc",
                                           Type::i32,
                                           builder.makeConst(int32_t(0)),
                                           Builder::Mutable));
    loweringInfo.malloc = "malloc";
    // TODO: more than a simple bump allocator that never frees or collects.
    module->addFunction(builder.makeFunction(
      "malloc",
      {Type::i32, Type::i32},
      {},
      builder.makeSequence(
        builder.makeGlobalSet(
          nextMalloc->name,
          builder.makeBinary(AddInt32,
                             builder.makeGlobalGet(nextMalloc->name, Type::i32),
                             builder.makeLocalGet(0, Type::i32))),
        builder.makeBinary(SubInt32,
                           builder.makeGlobalGet(nextMalloc->name, Type::i32),
                           builder.makeLocalGet(0, Type::i32)))));
  }

  void computeStructLayouts() {
    // Collect all the heap types in order to analyze them and decide on their
    // layout in linear memory.
    std::vector<HeapType> types;
    std::unordered_map<HeapType, Index> typeIndices;
    ModuleUtils::collectHeapTypes(*module, types, typeIndices);
    for (auto type : types) {
      if (type.isStruct()) {
        computeLayout(type, loweringInfo.layouts[type]);
        makeStructNew(type);
        makeStructSet(type);
        makeStructGet(type);
      } else if (type.isArray()) {
        makeArrayNew(type);
        makeArraySet(type);
        makeArrayGet(type);
      }
    }
  }

  void computeLayout(HeapType type, Layout& layout) {
    // A pointer to the RTT takes up the first bytes in the struct, so fields
    // start afterwards.
    Address nextField = loweringInfo.pointerSize;
    auto& fields = type.getStruct().fields;
    for (auto& field : fields) {
      layout.fieldOffsets.push_back(nextField);
      // TODO: packed types? for now, always use i32 for them
      nextField =
        nextField + getLoweredType(field.type, module->memory).getByteSize();
    }
    layout.size = nextField;
  }

  void makeStructNew(HeapType type) {
    auto typeName = module->typeNames[type].name.str;
    auto& fields = type.getStruct().fields;
    Builder builder(*module);
    for (bool withDefault : {true, false}) {
      std::vector<Type> params;
      // Store the values, by performing StructSet operations.
      for (Index i = 0; i < fields.size(); i++) {
        if (!withDefault) {
          params.push_back(fields[i].type);
        }
      }
      // Add the RTT parameter.
      auto rttParam = params.size();
      params.push_back(loweringInfo.pointerType);
      // We need one local to store the allocated value.
      auto alloc = params.size();
      std::vector<Expression*> list;
      // Malloc space for our struct.
      list.push_back(builder.makeLocalSet(
        alloc,
        builder.makeCall(
          loweringInfo.malloc,
          {builder.makeConst(int32_t(loweringInfo.layouts[type].size))},
          loweringInfo.pointerType)));
      // Store the rtt.
      list.push_back(builder.makeStore(
        loweringInfo.pointerSize,
        0,
        loweringInfo.pointerSize,
        builder.makeLocalGet(alloc, loweringInfo.pointerType),
        builder.makeLocalGet(rttParam, loweringInfo.pointerType),
        loweringInfo.pointerType));
      // Store the values, by performing StructSet operations.
      for (Index i = 0; i < fields.size(); i++) {
        Expression* value;
        if (withDefault) {
          value = LiteralUtils::makeZero(fields[i].type, *module);
        } else {
          auto paramType = fields[i].type;
          value = builder.makeLocalGet(i, paramType);
        }
        list.push_back(builder.makeCall(
          std::string("StructSet$") + typeName + '$' + std::to_string(i),
          {builder.makeLocalGet(alloc, loweringInfo.pointerType), value},
          Type::none));
      }
      // Return the pointer.
      list.push_back(builder.makeLocalGet(alloc, loweringInfo.pointerType));
      std::string name = "StructNew";
      if (withDefault) {
        name += "WithDefault";
      }
      module->addFunction(builder.makeFunction(name + '$' + typeName,
                                               {Type(params), Type::i32},
                                               {loweringInfo.pointerType},
                                               builder.makeBlock(list)));
    }
  }

  void makeStructSet(HeapType type) {
    auto& fields = type.getStruct().fields;
    Builder builder(*module);
    for (Index i = 0; i < fields.size(); i++) {
      auto& field = fields[i];
      auto loweredType = getLoweredType(field.type, module->memory);
      module->addFunction(builder.makeFunction(
        std::string("StructSet$") + module->typeNames[type].name.str + '$' +
          std::to_string(i),
        {{loweringInfo.pointerType, loweredType}, Type::none},
        {},
        builder.makeStore(loweredType.getByteSize(),
                          loweringInfo.layouts[type].fieldOffsets[i],
                          loweredType.getByteSize(),
                          builder.makeLocalGet(0, loweringInfo.pointerType),
                          builder.makeLocalGet(1, loweredType),
                          loweredType)));
    }
  }

  void makeStructGet(HeapType type) {
    auto& fields = type.getStruct().fields;
    Builder builder(*module);
    for (Index i = 0; i < fields.size(); i++) {
      auto& field = fields[i];
      auto loweredType = getLoweredType(field.type, module->memory);
      module->addFunction(builder.makeFunction(
        std::string("StructGet$") + module->typeNames[type].name.str + '$' +
          std::to_string(i),
        {loweringInfo.pointerType, loweredType},
        {},
        builder.makeLoad(loweredType.getByteSize(),
                         false, // TODO: signedness
                         loweringInfo.layouts[type].fieldOffsets[i],
                         loweredType.getByteSize(),
                         builder.makeLocalGet(0, loweringInfo.pointerType),
                         loweredType)));
    }
  }

  void makeArrayNew(HeapType type) {
    auto typeName = module->typeNames[type].name.str; // waka
    auto element = type.getArray().element;
    auto loweredType = getLoweredType(element.type, module->memory);
    Builder builder(*module);
    for (bool withDefault : {true, false}) {
      std::vector<Type> params;
      Index initParam = -1;
      if (!withDefault) {
        initParam = 0;
        params.push_back(loweredType);
      }
      // Add the size parameter.
      auto sizeParam = params.size();
      params.push_back(loweringInfo.pointerType);
      // Add the RTT parameter.
      auto rttParam = params.size();
      params.push_back(loweringInfo.pointerType);
      // Add a local to store the allocated value.
      auto alloc = params.size();
      // Add a local for the initialization loop.
      auto counter = params.size();
      std::vector<Expression*> list;
      // Malloc space for our Array.
      list.push_back(builder.makeLocalSet(
        alloc,
        builder.makeCall(
          loweringInfo.malloc,
          {builder.makeConst(int32_t(loweringInfo.layouts[type].size))},
          loweringInfo.pointerType)));
      // Store the size.
      list.push_back(builder.makeStore(
        loweringInfo.pointerSize,
        4,
        loweringInfo.pointerSize,
        builder.makeLocalGet(alloc, loweringInfo.pointerType),
        builder.makeLocalGet(sizeParam, loweringInfo.pointerType),
        loweringInfo.pointerType));
      // Store the rtt.
      list.push_back(builder.makeStore(
        loweringInfo.pointerSize,
        0,
        loweringInfo.pointerSize,
        builder.makeLocalGet(alloc, loweringInfo.pointerType),
        builder.makeLocalGet(rttParam, loweringInfo.pointerType),
        loweringInfo.pointerType));
      // Store the values, by performing ArraySet operations.
      Name loopName("loop");
      Name blockName("block");
      Expression* initialization;
      if (withDefault) {
        initialization = LiteralUtils::makeZero(loweredType, *module);
      } else {
        initialization = builder.makeLocalGet(initParam, loweredType);
      }
      initialization = builder.makeCall(
          std::string("ArraySet$") + typeName,
          {builder.makeLocalGet(alloc, loweringInfo.pointerType), initialization},
          Type::none);
      list.push_back(builder.makeLoop(
        loopName,
        builder.makeBlock(
          blockName,
          {builder.makeBreak(
             loopName,
             nullptr,
             builder.makeUnary(EqZInt32,
                               builder.makeLocalGet(counter, Type::i32))),
           initialization,
           builder.makeLocalSet(
             counter,
             builder.makeBinary(SubInt32,
                                builder.makeLocalGet(counter, Type::i32),
                                builder.makeConst(int32_t(1)))),
           builder.makeBreak(loopName)})));
      // Return the pointer.
      list.push_back(builder.makeLocalGet(alloc, loweringInfo.pointerType));
      std::string name = "ArrayNew";
      if (withDefault) {
        name += "WithDefault";
      }
      module->addFunction(builder.makeFunction(name + '$' + typeName,
                                               {Type(params), Type::i32},
                                               {loweringInfo.pointerType, loweringInfo.pointerType},
                                               builder.makeBlock(list)));
    }
  }

  Expression*
  makeArrayOffset(Type loweredType) {
    Builder builder(*module);
    return builder.makeBinary(
      AddInt32,
      builder.makeBinary(AddInt32, builder.makeLocalGet(0, loweringInfo.pointerType), builder.makeConst(int32_t(8))),
      builder.makeBinary(MulInt32,
                         builder.makeConst(int32_t(loweredType.getByteSize())),
                         builder.makeLocalGet(1, loweringInfo.pointerType)));
  }

  void makeArraySet(HeapType type) {
    auto element = type.getArray().element;
    auto loweredType = getLoweredType(element.type, module->memory);
    Builder builder(*module);
    module->addFunction(builder.makeFunction(
      std::string("ArraySet$") + module->typeNames[type].name.str + '$',
      {{loweringInfo.pointerType, loweringInfo.pointerType, loweredType}, Type::none},
      {},
      builder.makeStore(loweredType.getByteSize(),
                        0,
                        loweredType.getByteSize(),
                        makeArrayOffset(loweredType),
                        builder.makeLocalGet(1, loweredType),
                        loweredType)));
  }

  void makeArrayGet(HeapType type) {
    auto element = type.getArray().element;
    auto loweredType = getLoweredType(element.type, module->memory);
    Builder builder(*module);
    module->addFunction(builder.makeFunction(
      std::string("ArrayGet$") + module->typeNames[type].name.str,
      {{loweringInfo.pointerType, loweringInfo.pointerType}, loweredType},
      {},
      builder.makeLoad(loweredType.getByteSize(),
                       false, // TODO: signedness
                       0,
                       loweredType.getByteSize(),
                       makeArrayOffset(loweredType),
                       loweredType)));
  }

  void lowerCode(PassRunner* runner) {
    PassRunner subRunner(runner);
    subRunner.add(
      std::unique_ptr<LowerGCCode>(LowerGCCode(&loweringInfo).create()));
    subRunner.setIsNested(true);
    subRunner.run();

    LowerGCCode(&loweringInfo).walkModuleCode(module);
  }
};

Pass* createLowerGCPass() { return new LowerGC(); }

} // namespace wasm