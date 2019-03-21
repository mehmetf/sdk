// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fasta.transform_collections;

import 'dart:core' hide MapEntry;

import 'package:kernel/ast.dart'
    show
        Arguments,
        Block,
        BlockExpression,
        Class,
        DartType,
        DynamicType,
        Expression,
        ExpressionStatement,
        Field,
        ForInStatement,
        IfStatement,
        InterfaceType,
        InvalidExpression,
        ListLiteral,
        MapEntry,
        MapLiteral,
        MethodInvocation,
        Name,
        Not,
        NullLiteral,
        Procedure,
        PropertyGet,
        SetLiteral,
        Statement,
        StaticInvocation,
        TreeNode,
        VariableDeclaration,
        VariableGet;

import 'package:kernel/core_types.dart' show CoreTypes;

import 'package:kernel/visitor.dart' show Transformer;

import 'collections.dart'
    show
        ControlFlowElement,
        ControlFlowMapEntry,
        IfElement,
        IfMapEntry,
        SpreadElement,
        SpreadMapEntry;

import '../source/source_loader.dart' show SourceLoader;

import 'redirecting_factory_body.dart' show RedirectingFactoryBody;

class CollectionTransformer extends Transformer {
  final CoreTypes coreTypes;
  final Procedure listAdd;
  final Procedure setFactory;
  final Procedure setAdd;
  final Procedure objectEquals;
  final Procedure mapEntries;
  final Procedure mapPut;
  final Class mapEntryClass;
  final Field mapEntryKey;
  final Field mapEntryValue;

  static Procedure _findSetFactory(CoreTypes coreTypes) {
    Procedure factory = coreTypes.index.getMember('dart:core', 'Set', '');
    RedirectingFactoryBody body = factory?.function?.body;
    return body?.target;
  }

  CollectionTransformer(SourceLoader loader)
      : coreTypes = loader.coreTypes,
        listAdd = loader.coreTypes.index.getMember('dart:core', 'List', 'add'),
        setFactory = _findSetFactory(loader.coreTypes),
        setAdd = loader.coreTypes.index.getMember('dart:core', 'Set', 'add'),
        objectEquals =
            loader.coreTypes.index.getMember('dart:core', 'Object', '=='),
        mapEntries =
            loader.coreTypes.index.getMember('dart:core', 'Map', 'get:entries'),
        mapPut = loader.coreTypes.index.getMember('dart:core', 'Map', '[]='),
        mapEntryClass =
            loader.coreTypes.index.getClass('dart:core', 'MapEntry'),
        mapEntryKey =
            loader.coreTypes.index.getMember('dart:core', 'MapEntry', 'key'),
        mapEntryValue =
            loader.coreTypes.index.getMember('dart:core', 'MapEntry', 'value');

  TreeNode _translateListOrSet(
      Expression node, DartType elementType, List<Expression> elements,
      {bool isSet: false, bool isConst: false}) {
    // Translate elements in place up to the first non-expression, if any.
    int i = 0;
    for (; i < elements.length; ++i) {
      if (elements[i] is ControlFlowElement) break;
      elements[i] = elements[i].accept(this)..parent = node;
    }

    // If there were only expressions, we are done.
    if (i == elements.length) return node;

    if (isConst) {
      // We don't desugar const collections here.  Remove non-expression
      // elements for now so that they don't leak out of the transformation.
      for (; i < elements.length; ++i) {
        Expression element = elements[i];
        if (element is ControlFlowElement) {
          elements[i] = InvalidExpression('unimplemented collection element')
            ..fileOffset = element.fileOffset
            ..parent = node;
        } else {
          elements[i] = element.accept(this)..parent = node;
        }
      }
      return node;
    }

    // Build a block expression and create an empty list or set.
    VariableDeclaration result;
    if (isSet) {
      // TODO(kmillikin): When all the back ends handle set literals we can use
      // one here.
      result = new VariableDeclaration.forValue(
          new StaticInvocation(
              setFactory, new Arguments([], types: [elementType])),
          type: new InterfaceType(coreTypes.setClass, [elementType]),
          isFinal: true);
    } else {
      result = new VariableDeclaration.forValue(
          new ListLiteral([], typeArgument: elementType),
          type: new InterfaceType(coreTypes.listClass, [elementType]),
          isFinal: true);
    }
    List<Statement> body = [result];
    // Add the elements up to the first non-expression.
    for (int j = 0; j < i; ++j) {
      _addExpressionElement(elements[j], isSet, result, body);
    }
    // Translate the elements starting with the first non-expression.
    for (; i < elements.length; ++i) {
      _translateElement(elements[i], elementType, isSet, result, body);
    }

    return new BlockExpression(new Block(body), new VariableGet(result));
  }

  void _translateElement(Expression element, DartType elementType, bool isSet,
      VariableDeclaration result, List<Statement> body) {
    if (element is SpreadElement) {
      _translateSpreadElement(element, elementType, isSet, result, body);
    } else if (element is IfElement) {
      _translateIfElement(element, elementType, isSet, result, body);
    } else {
      _addExpressionElement(element.accept(this), isSet, result, body);
    }
  }

  void _addExpressionElement(Expression element, bool isSet,
      VariableDeclaration result, List<Statement> body) {
    body.add(new ExpressionStatement(new MethodInvocation(
        new VariableGet(result),
        new Name('add'),
        new Arguments([element]),
        isSet ? setAdd : listAdd)));
  }

  void _translateIfElement(IfElement element, DartType elementType, bool isSet,
      VariableDeclaration result, List<Statement> body) {
    List<Statement> thenBody = [];
    _translateElement(element.then, elementType, isSet, result, thenBody);
    List<Statement> elseBody;
    if (element.otherwise != null) {
      _translateElement(element.otherwise, elementType, isSet, result,
          elseBody = <Statement>[]);
    }
    Statement thenStatement =
        thenBody.length == 1 ? thenBody.first : new Block(thenBody);
    Statement elseStatement;
    if (elseBody != null && elseBody.isNotEmpty) {
      elseStatement =
          elseBody.length == 1 ? elseBody.first : new Block(elseBody);
    }
    body.add(new IfStatement(
        element.condition.accept(this), thenStatement, elseStatement));
  }

  void _translateSpreadElement(SpreadElement element, DartType elementType,
      bool isSet, VariableDeclaration result, List<Statement> body) {
    Expression value = element.expression.accept(this);
    // Null-aware spreads require testing the subexpression's value.
    VariableDeclaration temp;
    if (element.isNullAware) {
      temp = new VariableDeclaration.forValue(value,
          type: const DynamicType(), isFinal: true);
      body.add(temp);
      value = new VariableGet(temp);
    }

    VariableDeclaration elt =
        new VariableDeclaration(null, type: elementType, isFinal: true);
    Statement statement = new ForInStatement(
        elt,
        value,
        new ExpressionStatement(new MethodInvocation(
            new VariableGet(result),
            new Name('add'),
            new Arguments([new VariableGet(elt)]),
            isSet ? setAdd : listAdd)));

    if (element.isNullAware) {
      statement = new IfStatement(
          new Not(new MethodInvocation(new VariableGet(temp), new Name('=='),
              new Arguments([new NullLiteral()]), objectEquals)),
          statement,
          null);
    }
    body.add(statement);
  }

  @override
  TreeNode visitListLiteral(ListLiteral node) {
    return _translateListOrSet(node, node.typeArgument, node.expressions,
        isConst: node.isConst, isSet: false);
  }

  @override
  TreeNode visitSetLiteral(SetLiteral node) {
    return _translateListOrSet(node, node.typeArgument, node.expressions,
        isConst: node.isConst, isSet: true);
  }

  @override
  TreeNode visitMapLiteral(MapLiteral node) {
    // Translate entries in place up to the first control-flow entry, if any.
    int i = 0;
    for (; i < node.entries.length; ++i) {
      if (node.entries[i] is ControlFlowMapEntry) break;
      node.entries[i] = node.entries[i].accept(this)..parent = node;
    }

    // If there were no control-flow entries we are done.
    if (i == node.entries.length) return node;

    if (node.isConst) {
      // We don't desugar const maps here.  Remove control-flow entries for now
      // so that they don't leak out of the transformation.
      for (; i < node.entries.length; ++i) {
        MapEntry entry = node.entries[i];
        if (entry is ControlFlowMapEntry) {
          node.entries[i] = new MapEntry(
              InvalidExpression('unimplemented map entry')
                ..fileOffset = entry.fileOffset,
              new NullLiteral())
            ..parent = node;
        } else {
          node.entries[i] = node.entries[i].accept(this)..parent = node;
        }
      }
    }

    // Build a block expression and create an empty map.
    VariableDeclaration result = new VariableDeclaration.forValue(
        new MapLiteral([], keyType: node.keyType, valueType: node.valueType),
        type: new InterfaceType(
            coreTypes.mapClass, [node.keyType, node.valueType]),
        isFinal: true);
    List<Statement> body = [result];
    // Add all the entries up to the first control-flow entry.
    for (int j = 0; j < i; ++j) {
      _addNormalEntry(node.entries[j], result, body);
    }
    DartType mapEntryType =
        new InterfaceType(mapEntryClass, [node.keyType, node.valueType]);
    for (; i < node.entries.length; ++i) {
      _translateEntry(node.entries[i], mapEntryType, result, body);
    }

    return new BlockExpression(new Block(body), new VariableGet(result));
  }

  void _translateEntry(MapEntry entry, DartType entryType,
      VariableDeclaration result, List<Statement> body) {
    if (entry is SpreadMapEntry) {
      _translateSpreadEntry(entry, entryType, result, body);
    } else if (entry is IfMapEntry) {
      _translateIfEntry(entry, entryType, result, body);
    } else {
      _addNormalEntry(entry.accept(this), result, body);
    }
  }

  void _addNormalEntry(
      MapEntry entry, VariableDeclaration result, List<Statement> body) {
    body.add(new ExpressionStatement(new MethodInvocation(
        new VariableGet(result),
        new Name('[]='),
        new Arguments([entry.key, entry.value]),
        mapPut)));
  }

  void _translateIfEntry(IfMapEntry entry, DartType entryType,
      VariableDeclaration result, List<Statement> body) {
    List<Statement> thenBody = [];
    _translateEntry(entry.then, entryType, result, thenBody);
    List<Statement> elseBody;
    if (entry.otherwise != null) {
      _translateEntry(
          entry.otherwise, entryType, result, elseBody = <Statement>[]);
    }
    Statement thenStatement =
        thenBody.length == 1 ? thenBody.first : new Block(thenBody);
    Statement elseStatement;
    if (elseBody != null && elseBody.isNotEmpty) {
      elseStatement =
          elseBody.length == 1 ? elseBody.first : new Block(elseBody);
    }
    body.add(new IfStatement(
        entry.condition.accept(this), thenStatement, elseStatement));
  }

  void _translateSpreadEntry(SpreadMapEntry entry, DartType entryType,
      VariableDeclaration result, List<Statement> body) {
    Expression value = entry.expression.accept(this);
    // Null-aware spreads require testing the subexpression's value.
    VariableDeclaration temp;
    if (entry.isNullAware) {
      temp = new VariableDeclaration.forValue(value,
          type: coreTypes.mapClass.rawType);
      body.add(temp);
      value = new VariableGet(temp);
    }

    VariableDeclaration elt =
        new VariableDeclaration(null, type: entryType, isFinal: true);
    Statement statement = new ForInStatement(
        elt,
        new PropertyGet(value, new Name('entries'), mapEntries),
        new ExpressionStatement(new MethodInvocation(
            new VariableGet(result),
            new Name('[]='),
            new Arguments([
              new PropertyGet(
                  new VariableGet(elt), new Name('key'), mapEntryKey),
              new PropertyGet(
                  new VariableGet(elt), new Name('value'), mapEntryValue)
            ]),
            mapPut)));

    if (entry.isNullAware) {
      statement = new IfStatement(
          new Not(new MethodInvocation(new VariableGet(temp), new Name('=='),
              new Arguments([new NullLiteral()]), objectEquals)),
          statement,
          null);
    }
    body.add(statement);
  }
}
