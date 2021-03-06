/** 
 * This is a source file written in Peggy.js (https://peggyjs.org) syntax with
 * TS PEG.js plugin (https://github.com/metadevpro/ts-pegjs).
 * A typescript file converted from this file parses spec command files and
 * outputs a JavaScript object that resembles the Parser AST (abstract syntax tree, 
 * https://developer.mozilla.org/en-US/docs/Mozilla/Projects/SpiderMonkey/Parser_API).
 */

{
  interface Diagnostic {
    location: IFileRange,
    message: string,
    severity: vscode.DiagnosticSeverity,
  }

  const INVALID_STATEMENT = { type: 'InvalidStatement' };
  const NULL_EXPRESSION = { type: 'NullExpression' };
  const NULL_LITERAL = { type: 'Literal', value: null, raw: 'null'};

  const _diagnostics: Diagnostic[] = [];
  const _quoteStack: string[] = [];

  const _reservedKeywordRegExp = new RegExp(
    '^('
    + 'def|rdef|constant|local|global|un(?:def|global)|delete|shared|extern|array'
    + '|float|double|string|byte|short|long(?:64)?|u(?:byte|short|long(?:64)?)'
    + '|if|else|while|for|in|break|continue|exit|return|quit'
    + '|memstat|savstate|reconfig|getcounts|move_(?:all|cnt)|sync'
    + '|ls(?:cmd|def)|prdef|syms'
    + ')$'
  );

  const _ttyCommandRegExp = /^(c(?:d|e)|do|ho|le|m(?:b|d|e|h|r)|nd|s(?:e|o)|u(?:e|p|s))$/;
  const _patternRegExp = /^[a-zA-Z0-9_*?]+$/;

  /**
   * create diagnostic object and store it.
   */
  function pushDiagnostic(location: IFileRange, message: string, severity: vscode.DiagnosticSeverity) {
    _diagnostics.push({ location, message, severity });
  }

  /**
   * Return a new range object whose 'start' is identical to 'range' and the length is equal to 'length'.
   */
  function shortenRange(range: IFileRange, length: number): IFileRange {
    range.end.line = range.start.line;
    range.end.offset = range.start.offset + length;
    range.end.column = range.start.column + length;
    return range;
  }

  /**
   *
   */
  function diagnoseEmptyArray<T>(elements: T[] | null, loc: IFileRange, label: string, severity: vscode.DiagnosticSeverity) {
    if (!elements || elements.length === 0) {
      pushDiagnostic(loc, `Expected at least one ${label}.`, severity);
      return [];
    }
    return elements;
  }

  /**
   * Make array from an array of [identifier | null, separator, location, option?].
   */
  function diagnoseListItems<T>(elements: [T, string, IFileRange][], label: string, sepOption: number) {
    const items: T[] = [];
    for (let index = 0; index < elements.length; index++) {
      const [item, sep, locEach] = elements[index];
      if (!item) {
        pushDiagnostic(locEach, `Expected ${label}.`, vscode.DiagnosticSeverity.Error);
        continue;
      }
      items.push(item);

      if (index === elements.length - 1) {
        if (sep === ',') {
          pushDiagnostic(locEach, 'Trailing comma not allowed.', vscode.DiagnosticSeverity.Error);
        }
      } else if (sepOption === 1 && sep !== ',') {
        pushDiagnostic(locEach, 'Seprator must be a comma.', vscode.DiagnosticSeverity.Error);
      } else if (sepOption === 2 && sep !== ' ') {
        pushDiagnostic(locEach, 'Seprator must be a whitespace.', vscode.DiagnosticSeverity.Error);
      }
    }
    return items;
  }

  /**
   * Make Variable Declarators from an array of [identifier | null, separator, location, option?].
   */
  function makeDeclarators(elements: [any, string, IFileRange, any][] | null, locAll: IFileRange, label: string, allows_assign: boolean) {
    if (!elements || elements.length === 0) {
      pushDiagnostic(locAll, `Expected at least one ${label}.`, vscode.DiagnosticSeverity.Error);
      return [];
    } else if (elements[elements.length - 1][1] === ',') {
      pushDiagnostic(elements[elements.length - 1][2], `Trailing comma not allowed.`, vscode.DiagnosticSeverity.Error);
    } else if (elements.some((item: [any, string, IFileRange, any]) => item[3].init !== null)) {
      if (!allows_assign) {
        pushDiagnostic(locAll, `Assignment not allowed.`, vscode.DiagnosticSeverity.Error);
      } else if (elements.length > 1) {
        pushDiagnostic(locAll, `Only one variable per statement can be declared and initialized.`, vscode.DiagnosticSeverity.Error);
      }
    }

    const declarators: any[] = [];
    for (const [identifier, separator, locEach, option] of elements) {
      if (!identifier) {
        pushDiagnostic(locEach, `Expected ${label}.`, vscode.DiagnosticSeverity.Error);
        continue;
      }
      let obj = { type: 'VariableDeclarator', id: identifier};
      if (option) {
        Object.assign(obj, option);
      }
      declarators.push(obj);
    }
    
    return declarators;
  }

  /**
   * Make a sequence expression from array.
   * If an array is empty or null, null is returned.
   * If an array has only one Expression, it returns the Expression itself (not array).
   * If an array has two or more expressions, it returns a Sequence Expression containing the elements.
   */
  function makeSequenceExpression(elements: any[] | null) {
    if (elements === null || elements.length === 0) {
      return null;
    } else if (elements.length === 1) {
      return elements[0];
    } else {
      return { type: 'SequenceExpression', expressions: elements };
    }
  }

  /**
   * Make nested expression for binary operation.
   * head must be an expression. tails must be [string, any]
   */
  function getBinaryExpression(head: any, tails: [string, any], option = 0) {
    return tails.reduce((accumulator: any, currentValue: any) => {
      const op = currentValue[0];
      const term = currentValue[1];
      return {
        type: option === 1 ? 'LogicalExpression' : 'BinaryExpression',
        operator: op,
        left: accumulator,
        right: term,
      };
    }, head);
  }

  /**
   *
   */
  function testIfQuoteIsAvailable(quote: string): boolean {
    if (quote === '"' && (_quoteStack.includes('"') || _quoteStack.includes('\\"'))) {
      return false;
    } else if (quote === "'" && (_quoteStack.includes("'") || _quoteStack.includes("\\'"))) {
      return false;
    } else if (quote === '\\"' && _quoteStack.includes('\\"')) {
      return false;
    } else if (quote === "\\'" && _quoteStack.includes("\\'")) {
      return false;
    } else {
      return true;
    }
  }

  /**
   *
   */
  function testIfEscapedCharIsAvailable(escapedChar: string): boolean {
    return _quoteStack.every(quote => quote.length !== 2 || quote.substr(1, 1) !== escapedChar);
  }

  /**
   *
   */
  function testIfUnescapedCharIsAvailable(unescapedChar: string): boolean {
    return _quoteStack.every(quote => quote.length !== 1 || quote !== unescapedChar);
  }
}


// # MAIN

start =
  body:stmt* {
    return {
      type: 'Program',
      body: body,
      exDiagnostics: _diagnostics,
    };
  }


// # AUXILIARIES

eol 'EOL' = '\n' / '\r\n'
eof 'EOF' = !.
line_comment 'line comment' = '#' p:$(!eol .)* (eol / eof) { return {type: 'Line', value: p }; }

quotation_mark 'quotation mark' = $('\\'? ('"' / "'"))

eos_lookahead    = eof { } / & quotation_mark { } / & '}' { }
eos_no_lookahead = eol { } / line_comment / ';' eol? { } 
eos              = eos_no_lookahead  / eos_lookahead

triple_quote = '"""'
block_comment 'block comment' =
  triple_quote p:$(!triple_quote .)* closer:triple_quote? {
    if (!closer) {
      pushDiagnostic(shortenRange(location(), 3), 'Unterminated docstring.', vscode.DiagnosticSeverity.Error);
    }
    return { type: 'Block', value: p };
  }

space = $(' ' / '\t' / '\\' eol / block_comment { pushDiagnostic(location(), 'Inline docstring not recommended.', vscode.DiagnosticSeverity.Information); return text(); })
_1_ 'whiltespace'         = space+
_0_ 'optional whitespace' = space*

word = [a-zA-Z0-9_]
list_sep =
  _0_ ',' _0_ { return ','; } / _1_ { return ' '; }
comma_sep =
  _0_ ',' _0_ { return ','; }

// # STATEMENTS
 
 /**
  * BNF> statement
  * Statement with or without leading comments.
  */
stmt 'statement' =
  comments:leading_comment* statement:(empty_stmt / nonempty_stmt) {
    if (comments && comments.length > 0) {
      statement.leadingComments = comments;
    }
    return statement;
  }
  /
  comments:leading_comment+ eos_lookahead {
    return { type: 'EmptyStatement', loc: location(), leadingComments:comments };
  }

/**
 * Empty line containing only whitespaces and a line or block comment,
 * which is treated as the leading comments of the succeeding statement.
 */
leading_comment 'empty statement with comment' =
  $[ \t]* p:(line_comment / q:block_comment [ \t]* (eol / eof) { return q; }) {
    return p;
  }

/**
 * Empty statement. It may contains line or block comments.
 */
empty_stmt 'empty statement' =
  (_0_ eos_no_lookahead / _1_ eos_lookahead) {
    return { type: 'EmptyStatement', loc: location() };
  }

/**
 * Nonempty statement.
 */
nonempty_stmt 'nonempty statement' =
  _0_ p:(
    block_stmt
    / if_stmt / while_stmt / for_stmt / break_stmt / continue_stmt / return_stmt / exit_stmt
    / macro_def / undef_stmt / rdef_stmt / data_array_def / extern_array_def / variable_def / constant_def
    / delete_stmt / pattern_stmt / builtin_macro_stmt / expr_stmt
  ) {
    p.loc = location();
    return p;
  }

/**
 * <BNF> compound-statement:
 *         { statement-list }
 */
block_stmt 'block statement' =
  '{' _0_ eos? stmts:stmt* _0_ closer:'}'? tail:(_0_ p:eos { return p; })? {
    if (!closer) {
      pushDiagnostic(shortenRange(location(), 1), 'Unterminated block statement.', vscode.DiagnosticSeverity.Error);
    }
    const obj: any = {
      type: 'BlockStatement',
      body: stmts ? stmts : [],
    };
    if (tail) {
      obj.trailingComments = [tail];
    }
    return obj;
  }


// ## FLOW STATEMENTS

/**
 * <BNF> if ( expression ) statement
 * <BNF> if ( expression ) statement else statement
 */
if_stmt 'if statement' =
  test:(
    'if' _0_ test:(
      '(' _0_ test:expr_solo_forced? _0_ closer:')'? {
        if (!test) {
          pushDiagnostic(location(), 'The test expression of if-statement must not be empty.', vscode.DiagnosticSeverity.Error);
        } else if (!closer) {
          pushDiagnostic(shortenRange(location(), 1), 'Unterminated parenthesis.', vscode.DiagnosticSeverity.Error);
        }
        return test;
      }
    ) {return test; }
    /
    ('ifd' / 'ifp') { return NULL_EXPRESSION; }
  ) _0_ (eol / line_comment)? cons:(
    cons:nonempty_stmt? {
      if (!cons) {
        pushDiagnostic(location(), 'The consequent clause of if-statement must not be empty.', vscode.DiagnosticSeverity.Error);
      }
      return cons;
    }
  ) alt:(
    _0_ 'else' !word _0_ (eol / line_comment)? alt:(
      alt:nonempty_stmt? {
        if (!alt) {
          pushDiagnostic(location(), 'The altanative clause of if-statement must not be empty.', vscode.DiagnosticSeverity.Error);
        }
        return alt;
      }
    ) { return alt; }
  )? {
    return {
      type: 'IfStatement',
      test: test,
      consequent: cons,
      alternate: alt,
    };
  }

/**
 * <BNF> while ( experssion ) statement
 */
while_stmt 'while statement' =
  'while' _0_ test:(
    '(' _0_ test:expr_solo_forced? _0_ closer:')'? _0_ (eol / line_comment)? {
      if (!test) {
        pushDiagnostic(shortenRange(location(), 1), 'The test expression of while-statement must not be empty.', vscode.DiagnosticSeverity.Error);
      } else if (!closer) {
        pushDiagnostic(shortenRange(location(), 1), 'Unterminated parenthesis.', vscode.DiagnosticSeverity.Error);
      }
      return test;
    }
  ) body:(
    body:nonempty_stmt? {
      if (!body) {
        pushDiagnostic(location(), 'The body of while-statement must not be empty.', vscode.DiagnosticSeverity.Error);
      }
      return body;
    }
  ) {
    return {
      type: 'WhileStatement',
      test: test,
      body: body,
    };
  }
  
/**
 * <BNF> for ( expr_opt; expr_opt; expr_opt ) statement
 * <BNF> for (identifier in assoc-array ) statement
 * While the first and third expression in a regular for-loop can be comma-separated expressions,
 * the second expression must be a single expression.
 */
for_stmt 'for statement' =
  'for' _0_ stmt:(
    '(' _0_ stmt:(
      init:expr_solo_list? _0_ ';' _0_ test:expr_solo_forced? _0_ ';' _0_ update:expr_solo_list? {
        return {
          type: 'ForStatement',
          init: makeSequenceExpression(init),
          test: test,
          update: makeSequenceExpression(update),
        };
      }
      /
      ll:identifier _0_ 'in' !word _0_ rr:assoc_array {
        return {
          type: 'ForInStatement',
          left: ll,
          right: rr,
          each: false
        };
      }
    ) _0_ closer:')'? {
      if (!closer) {
        pushDiagnostic(shortenRange(location(), 1), 'Unterminated parenthesis.', vscode.DiagnosticSeverity.Error);
      }
      return stmt;
    }
  ) _0_ (eol / line_comment)? body:(
    body:nonempty_stmt? {
      if (!body) {
        pushDiagnostic(location(), 'The body of for-statement must not be empty.', vscode.DiagnosticSeverity.Error);
      }
      return body;
    }
  ) {
    stmt.body = body;
    return stmt;
  }

/**
 * <BNF> break [;]
 */
break_stmt 'break statement' =
  'break' _0_ eos {
    return { type: 'BreakStatement', label: null, };
  }

/**
 * <BNF> continue [;]
 */
continue_stmt 'continue statement' =
  'continue' _0_ eos {
    return { type: 'ContinueStatement', label: null, };
  }

/**
 * <BNF> return [expression] [;]
 * <NOTICE> not documented in Grammer Rules.
 */
return_stmt 'return statement' =
  'return' !word _0_ p:expr_solo? _0_ eos {
    return { type: 'ReturnStatement', argument: p, };
  }

/**
 * <BNF> exit [;]
 * <NOTICE> no correspondence item in Parser AST.
 * Currently not used.
 */
exit_stmt 'exit statement' =
  'exit' _0_ eos {
    return { type: 'ExitStatement', };
  }


 // ## DECLARATIONS

/**
 * <BNF> def identifier string-constant [;]
 *
 * body in FunctionDeclaration in the Parser AST must be BlockStatement or Expression.
 * params in FunctionDeclaration in the Parser AST must not be null.
 */
macro_def 'macro declaration' =
  'def' _1_ identifier:identifier_w_check _0_ params:(
    '(' _0_ params:_identifier_list_item* _0_ closer:')'? _0_ {
      if (!closer) {
        pushDiagnostic(shortenRange(location(), 1), 'Unterminated parenthesis.', vscode.DiagnosticSeverity.Error);
      }
      return params ? diagnoseListItems(params, 'identifier', 1) : [];
    }
  )?
  _0_ body:(
    opener:quotation_mark
    & {
      const flag = testIfQuoteIsAvailable(opener);
      if (flag) { _quoteStack.push(opener); }
      return flag;
    }
    _0_ eos? body:stmt*
    closer:quotation_mark?
    & {
      // console.log(location(), text());
      const flag = (!closer || opener === closer);
      if (flag) { _quoteStack.pop(); }
      return flag;
    }
    _0_ eos {
      if (!closer) {
        pushDiagnostic(shortenRange(location(), opener.length), 'Unterminated macro definition.', vscode.DiagnosticSeverity.Error);
      }
      return body;
    }
    / body:stmt? _0_ eos {
      pushDiagnostic(shortenRange(location(), 1), 'Expected macro definition body, which must be embraced with quotes.', vscode.DiagnosticSeverity.Error);
      return body;
    }
  ) {
    return {
      type: 'FunctionDeclaration',
      id: identifier,
      params: params,
      // defaults: [ Expression ],
      // rest: Identifier | null,
      body: body,
      generator: false,
      expression: false,
    };
  }

_identifier_list_item =
  id:identifier_w_check sep:list_sep? {
    return [id, sep, location()];
  }
  / sep:list_sep {
    return [undefined, sep, location()];
  }

/**
 * <BNF> undef identifier-list [;]
 */
undef_stmt =
  'undef' _1_ items:(
    items:_identifier_list_item* {
      diagnoseEmptyArray(items, location(), 'identifier', vscode.DiagnosticSeverity.Error);
      return items;
    }
  ) _0_ eos {
    const nodes = diagnoseListItems(items, 'identifier', 0);
    return {
      type: 'MacroStatement',
      callee: { type: 'Identifier', name: 'undef', },
      arguments: nodes,
    };
  }

/**
 * <BNF> rdef identifier expression [;]
 */
rdef_stmt =
  'rdef' _1_ p:(
    id:identifier_w_check _0_ params:(
      '(' _0_ params:_identifier_list_item* _0_ closer:')'? _0_ {
        if (!closer) {
          pushDiagnostic(shortenRange(location(), 1), 'Unterminated parenthesis.', vscode.DiagnosticSeverity.Error);
        }
        return params ? diagnoseListItems(params, 'identifier', 1) : [];
      }
    )? expr:(
      expr:expr_multi? {
        if (!expr) {
          pushDiagnostic(location(), `Expected an expression.`, vscode.DiagnosticSeverity.Error);
        }
        return expr;
      }
    ) {
      return [id, expr];
    }
  )? _0_ eos {
    if (!p) {
      pushDiagnostic(location(), `Expected following identifier and expression.`, vscode.DiagnosticSeverity.Error);
      return INVALID_STATEMENT;
    }
    return {
      type: 'MacroStatement',
      callee: { type: 'Identifier', name: 'rdef', },
      arguments: p,
    };
  }

/**
 * <BNF> local data-array-declaration [;]
 * <BNF> global data-array-declaration [;]
 * <BNF> shared data-array-declaration [;]
 * <BNF> extern shared data-array-declaration [;]
 * <BNF>
 * <BNF> data-array-declaration;
 * <BNF>   array identifier[expression]
 * <BNF>   data-array-type array identifier[expression]
 * <BNF>   array identifier [expression][expression]
 * <BNF>   data-array-type array identifier[expression][expression]
 */

data_array_def 'data-array declaration' =
  scope:(
    ('local' / 'global' / 'shared') _1_
  )? unit:(
    _data_array_unit _1_
  )? 'array' _1_ items:_data_array_list_item* _0_ eos {
    return {
      type: 'VariableDeclaration',
      declarations: makeDeclarators(items, location(), 'array identifier', true),
      kind: 'let',
      exType: 'data-array',
      exScope: scope ? scope[0] : undefined,
      exUnit: unit ? unit[0] : undefined,
    };
  }

_data_array_unit =
  'string' / 'float' / 'double'
  / 'byte' / 'short' / $('long' '64'?)
  / 'ubyte' / 'ushort' / $('ulong' '64'?)

_data_array_list_item =
  id:identifier_w_check sizes:(
    _0_ p:(
      '[' _0_ expr:expr_solo_forced? _0_ closer:']'? {
        if (!closer) {
          pushDiagnostic(shortenRange(location(), 1), 'Unterminated bracket.', vscode.DiagnosticSeverity.Error);
        } else if (!expr) {
          pushDiagnostic(location(), 'Array size must be sepcified.', vscode.DiagnosticSeverity.Error);
          expr = NULL_LITERAL;
        }
        return expr;
      }
    ) { return p; }
  )* init:(
    _0_ op:assignment_op _0_ term:expr_multi? {
      if (op !== '=') {
        pushDiagnostic(location(), `Invalid operator: \"${op}\". Only \"=\" is allowed.`, vscode.DiagnosticSeverity.Error);
      }
      if (!term) {
        pushDiagnostic(location(), `Expected an expression following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
        term = NULL_LITERAL;
      } else if (term.type !== 'ObjectExpression' && term.type !== 'ArrayExpression') {
        pushDiagnostic(location(), 'Only array can be assigned.', vscode.DiagnosticSeverity.Error);
      }
      return term;
    }
  )? sep:list_sep? {
    if (!sizes || sizes.length === 0) {
      pushDiagnostic(location(), 'Array size must be sepcified.', vscode.DiagnosticSeverity.Error);
    }
    return [ id, sep, location(), { exSizes: sizes, init: init } ];
  }
  /
  sep:list_sep {
    return [ undefined, sep, location(), undefined];
  }  

extern_array_def =
  'extern' _1_ 'shared' _1_ 'array' _1_ items:_extern_array_list_item* _0_ eos {
    return {
      type: 'VariableDeclaration',
      declarations: makeDeclarators(items, location(), 'external array identifier', false),
      kind: 'let',
      exType: 'data-array',
      exScope: 'extern',
      exSize: undefined,
    };
  }

_extern_array_list_item =
  spec_pid:(
    spec:$word+ _0_ ':' _0_ pid:(
      pid:$word+ _0_ ':' _0_ { return pid; }
    )? {return [spec, pid]; }
  )? id:identifier_w_check sep:list_sep? {
    const spec = spec_pid ? spec_pid[0] : null;
    const pid = spec_pid ? spec_pid[1] : null;
    return [id, sep, location(), { exSpec: spec, exPid: pid }];
  }
  /
  sep:list_sep {
    return [undefined, sep, location(), undefined];
  }
    
/**
 * <BNF> local identifier-list [;]
 * <BNF> global identifier-list [;]
 * <BNF> unglobal identifier-list [;]
 */
variable_def 'variable declaration' =
  scope:('local' / 'global' / 'unglobal') _1_ items:_variable_list_item* _0_ eos {
    return {
      type: 'VariableDeclaration',
      declarations: makeDeclarators(items, location(), 'variable identifier', scope !== 'unglobal'),
      kind: 'let',
      exScope: scope,
    };
  }

_variable_list_item =
  id:identifier_w_check bracket:(
    _0_ p:(
      '[' _0_ closer:']'? {
        if (!closer) {
          pushDiagnostic(shortenRange(location(), 1), 'Unterminated bracket.', vscode.DiagnosticSeverity.Error);
        }
        return true;
      }
    ) { return p; }
  )? init:(
    _0_ op:assignment_op _0_ term:expr_multi? {
      if (op !== '=') {
        pushDiagnostic(location(), `Invalid operator: \"${op}\". Only \"=\" is allowed.`, vscode.DiagnosticSeverity.Error);
      }
      if (!term) {
        pushDiagnostic(location(), `Expected an expression following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
        term = NULL_LITERAL;
      }
      return term;
    }
  )? sep:list_sep? {
    return [ id, sep, location(), { exType: bracket !== null ? 'assoc-array' : 'scalar', init: init, } ];
  }
  /
  sep:list_sep {
    return [ undefined, sep, location(), undefined];
  }

/**
 * <BNF> constant identifier expression [;]
 * <BNF> constant identifier = expression [;]
 */
constant_def 'constant declaration' =
  'constant' _1_ items:(
    id:identifier_w_check !word _0_ '='? _0_ init:expr_multi? sep:comma_sep? {
      return [id, init, sep, location()];
    }
  )* _0_ eos {
    if (!items || items.length === 0) {
      pushDiagnostic(location(), `Expected following identifier and initial value.`, vscode.DiagnosticSeverity.Error);
      return INVALID_STATEMENT;
    }

    const item = items[0];

    if (items.length > 1) {
      pushDiagnostic(location(), `Only single constant can be decleared per statement.`, vscode.DiagnosticSeverity.Error);
    } else if (item[2]) {
      pushDiagnostic(location(), `Trailing comma not allowed.`, vscode.DiagnosticSeverity.Error);
    } else if (!item[1]) {
      pushDiagnostic(item[3], `Expected initial value.`, vscode.DiagnosticSeverity.Error);
      item[1] = NULL_LITERAL;
    }

    return {
      type: 'VariableDeclaration',
      declarations: [
        {
          type: 'VariableDeclarator',
          id: item[0],
          init: item[1],
        },
      ],
      kind: 'const',
    };
  }

/*
 * OTHER STATEMENTS
 */

/**
 * <BNF> delete assoc-elem-list [;]
 * <BNF> delete assoc-array [;]
 *
 * The BNF in the Grammer Rules does not seems described correctly.
 * Deleting associative array without specifying indexes, as shown below, yields a syntax error.
 * > global arr
 * > arr = [1: "foo"];
 * > delete arr
 */
delete_stmt =
  'delete' _1_ items:(
    items:_assoc_elem_list_item* {
      diagnoseEmptyArray(items, location(), 'associative array', vscode.DiagnosticSeverity.Error);
      return items;
    }
   ) _0_ eos {
    const nodes = diagnoseListItems(items, 'associative array', 0);
    return {
      type: 'UnaryExpression',
      operator: 'delete',
      argument: (nodes && nodes.length > 0)? makeSequenceExpression(nodes) : NULL_EXPRESSION,
      prefix: true,
    };
  }

_assoc_elem_list_item =
  node:assoc_array sep:list_sep? {
    return [node, sep, location(), undefined];
  }
  /
  sep:list_sep {
    return [undefined, sep, location(), undefined];
  }

/**
 * <BNF> lscmd pattern-list-opt [;]
 * <BNF> syms pattern-list-opt [;]
 * <BNF> lsdef pattern-list-opt [;]
 * <BNF> prdef pattern-list-opt [;]
 */
pattern_stmt =
  name:('lscmd' / 'lsdef' / 'prdef' / 'syms') !word _0_ items:_pattern_list_item* _0_ eos {
    let nodes: any[] = [];
    if (items && items.length > 0) {
      nodes = diagnoseListItems(items, 'pattern', 2);
    }
    return {
      type: 'MacroStatement',
      callee: { type: 'Identifier', name: name, },
      arguments: nodes,
    };
  }

_pattern_list_item =
  node:pattern_w_check sep:list_sep? {
    return [node, sep, location()];
  }
  /
  sep:list_sep {
    return [undefined, sep, location()];
  }

pattern_w_check =
  macro_argument
  /
  p:string_literal {
    pushDiagnostic(location(), 'Expected a pattern.', vscode.DiagnosticSeverity.Error);
    return p;
  }
  /
  (!space !eos .)+ {
    if (!_patternRegExp.test(text())) {
      pushDiagnostic(location(), 'Expected a pattern.', vscode.DiagnosticSeverity.Error);
    }
    return {
      type: 'literal',
      value: text(),
      raw: text(),
    };
  }

/**
 * <BNF> memstat [;]
 * <BNF> savstate [;]
 * <BNF> reconfig [;]
 * <BNF> getcounts [;]
 * <BNF> move_all [;]
 * <BNF> move_cnt [;]
 * <BNF> sync [;]
 */
builtin_macro_stmt =
  name:('memstat' / 'savstate' / 'reconfig' / 'getcounts' / 'move_all' / 'move_cnt' / 'sync') _0_ eos {
    return {
      type: 'MacroStatement',
      callee: { type: 'Identifier', name: name, },
      arguments: [],
    };
  }

/**
 * <BNF> expression [;]
 */
expr_stmt 'expression statement' =
  items:expr_multi_list _0_ eos {
    return {
      type: 'ExpressionStatement',
      expression: makeSequenceExpression(items),
    };
  }

/*
 * EXPRESSION
 *
 * The priority of the operators are not documented in the Grammer Rules.
 * Instad, this PEG grammer follows that of C-language (https://en.wikipedia.org/wiki/Order_of_operations).
 * 
 * There are two operators not included in C-language, 'in' operator and empty operator for string concatenation.
 * It seems the priority of string concatenation is higher than that of assignment but
 * lower than that of ternary operators.
 */

/**
 * expression that does not include concatenation.
 *
 * function_call and update_expr must precede lvalue.
 * update_expr must precede unary_expr.
 */
expr_solo 'expression' =
  expr_term15

/**
 * The core expression rules with operators haiving the 1st and 2nd priorities.
 */
expr_term2 =
  string_literal / numeric_literal / array_literal / expr_block / function_call
  / update_expr / unary_expr
  / lvalue / invalid_expr

/**
 * <BNF> identifier
 *
 * The symbols $1, $2, ... within ordinary macros are replaced by 
 * the arguments with which the macro is invoked.
 * Therefore, it is difficult to gramatically define these symbols.
 * Expediently, this PEG grammer treats them as identifiers.
 */
identifier 'identifier' =
  strict_identifier
  /
  macro_argument
  /
  op:'@' _0_ arg:expr_solo? {
    if (!arg) {
      pushDiagnostic(location(), `Expected an expression following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
    }
    return {
      type: 'UnaryExpression',
      operator: '@',
      argument: arg ? arg : NULL_LITERAL,
      prefix: true,
    };
  }

strict_identifier =
  name:$([a-zA-Z_][a-zA-Z0-9_]*) {
    if (_reservedKeywordRegExp.test(name)) {
      pushDiagnostic(location(), `${name} is a reserved keyword.`, vscode.DiagnosticSeverity.Error);
    // } else if (name === 'const') {
    //   pushDiagnostic(location(), `Using ${name} for \"constant\"?`, vscode.DiagnosticSeverity.Information);
    // } else if (name === 'elseif' || name === 'elif') {
    //   pushDiagnostic(location(), `Using ${name} for \"else if\"?`, vscode.DiagnosticSeverity.Information);
    }
    return {
      type: 'Identifier',
      name: name,
    };
  }

macro_argument =
  name:$('\\'? '$' ('#' / '*' / [0-9]+)) {
    return {
      type: 'Identifier',
      name: name,
    };
  }

// / [a-zA-Z0-9_.+\-*/%!?^~\\]+
identifier_w_check =
  identifier / invalid_expr
  // / [a-zA-Z0-9_.+\-*/%!?^~\\]+ {
  //   pushDiagnostic(location(), 'invalid as an identifier', vscode.DiagnosticSeverity.Error);
  //   return {
  //     type: 'Identifier',
  //     name: text(),
  //   };
  // }

/**
 * <BNF> identifier
 * <BNF> identifier[expression]
 * <BNF> identifier[expression][expression]
 *
 * e.g., _foo12, bar[myfunc(a)], bar[], bar[:], bar[:4], bar[2:], bar[1, 2, 3:5], ...
 */
lvalue 'left value' =
  id:identifier arr_dims:(
    _0_ arr_dim:array_element { return arr_dim; }
  )* {
    return arr_dims.reduce((accumulator: any, currentValue: any) => {
      return {
        type: 'MemberExpression',
        object: accumulator,
        property: currentValue,
        computed: true,
      };
    }, id);
  }

array_element =
  _0_ '[' _0_ item_0:slicable_index? items_1_n:(
    sep:comma_sep item:slicable_index? { return item ? item : NULL_LITERAL; }
  )* _0_ closer:']'? {
    if (!closer) {
      pushDiagnostic(shortenRange(location(), 1), 'Unterminated bracket.', vscode.DiagnosticSeverity.Error);
    }
    item_0 = item_0 ? item_0 : NULL_LITERAL;
    if (items_1_n && items_1_n.length > 0) {
      return {
        type: 'SequenceExpression',
        expressions: [item_0].concat(items_1_n),
      };
    } else {
      return item_0;
    }
  }

/**
 * respective item of the comma-separated index. It can be:
 * - expression
 * - expression? : expression?
 */
slicable_index =
  ll:expr_multi? _0_ ':' _0_ rr:expr_multi? {
    return {
      type: 'BinaryExpression',
      operator: ':',
      left: ll ? ll : NULL_LITERAL,
      right: rr ? rr : NULL_LITERAL,
    };
  }
  /
  expr_multi

assoc_array = lvalue

invalid_expr =
  '{' eos? _0_ stmts:expr_multi_list? _0_ '}'? eos? {
    pushDiagnostic(location(), 'Braces are to bundle statements. Use parentheses "()" for expressions.', vscode.DiagnosticSeverity.Error);
    return NULL_EXPRESSION;
  }
  /
  value:$[^#,'"(){}[\];: \t\r\n\\]+ {
    pushDiagnostic(location(), 'Invalid expression. It should be quoted if it is a string.', vscode.DiagnosticSeverity.Warning);
    return {
      type: 'Literal',
      value: text(),
      raw: text(),
    };
  }
// +-*/%^&|=

/**
 * <BNF> string-constant
 *
 * e.g., "foo,\"bar\"\n123", \'foo\'
 */
string_literal 'string literal' =
  opener:quotation_mark
  & {
    const flag = testIfQuoteIsAvailable(opener);
    if (flag) { _quoteStack.push(opener); }
    return flag;
  }
  chars:(
    '\\' q:(
      p:[abfnrt'"\\$\n]
      & { return testIfEscapedCharIsAvailable(p); }
        {
          switch (p) {
            case 'a': return '\x07';
            case 'b': return '\b';
            case 'f': return '\f';
            case 'n': return '\n';
            case 'r': return '\r';
            case 't': return '\t';
            case '\\': return '\\';
            case '\'': return '\'';
            case '\"': return '\"';
            case '$': return '$';
            case '\n': return '';
            default: return '';
          }
        }
      /
      p:$([0-7][0-7]?[0-7]?) { return String.fromCharCode(parseInt(p, 8)); }
      /
      p:'[' cmd:$word+ ']' {
        if (!_ttyCommandRegExp.test(cmd)) {
          pushDiagnostic(location(), `${cmd} is not a TTY command.`, vscode.DiagnosticSeverity.Warning);
        }
        return text();
      }
      /
      p:.
      & { return testIfEscapedCharIsAvailable(p); }
        {
          const loc = location();
          loc.start.offset -= 1;
          loc.start.column -= 1;
          pushDiagnostic(loc, 'Unknown escape sequence.', vscode.DiagnosticSeverity.Warning);
          return p;
        }
    ) { return q; }
    /
    r:[^\\]
    & { return testIfUnescapedCharIsAvailable(r); }
      {
        if (!testIfEscapedCharIsAvailable(r)) {
          pushDiagnostic(location(), 'Quotation symbol not allowed here.', vscode.DiagnosticSeverity.Error);
        }
        return r;
      }
  )*
  closer:quotation_mark? {
    if (!closer) { pushDiagnostic(shortenRange(location(), opener.length), 'Unterminated string literal.', vscode.DiagnosticSeverity.Error); }
    _quoteStack.pop();
    return {
      type: 'Literal',
      value: chars.join(''),
      raw: text(),
    };
  }

/** 
 * <BNF> numeric-constant
 *
 * e.g., 0.1, 1e-3, 19, 017, 0x1f
 */
numeric_literal 'numeric literal' =
  out:(float / hexadecimal / octal / decimal) {
    return {
      type: 'Literal',
      value: out[1],
      raw: out[0],
    };
  }

float =
  (([0-9]+ (exponent / '.' [0-9]* exponent?)) / '.' [0-9]+ exponent?) {
    return [text(), parseFloat(text())];
  }

hexadecimal =
  '0' [xX] body:$[0-9a-fA-F]+ {
    return [text(), parseInt(body, 16)];
  }

octal =
  '0' body:$[0-7]+ {
    return [text(), parseInt(body, 8)];
  }

decimal =
  [0-9]+ {
    return [text(), parseInt(text(), 10)];
  }

exponent =
  [eE] [+-]? [0-9]+

/**
 * Array literals used in assignment operation.
 * its BNF is undocumented in the Grammer Rules.
 * e.g., [ var0, 1+2, "test"], ["foo": 0x12, "bar": var1]
 */
array_literal 'array literal' =
  '[' _0_ item_0:(
    item:array_item? {
      if (!item) {
        pushDiagnostic(location(), 'Expected an array element.', vscode.DiagnosticSeverity.Error);
        return NULL_LITERAL;
      }
      return item;
    }
  ) items_1_n:(
    sep:comma_sep item:array_item? {
      if (!item) {
        pushDiagnostic(location(), 'Expected an array element.', vscode.DiagnosticSeverity.Error);
        return NULL_LITERAL;
      }
      return item;
    }
  )* _0_ closer:']'? {
    if (!closer) {
      pushDiagnostic(shortenRange(location(), 1), 'Unterminated bracket.', vscode.DiagnosticSeverity.Error);
    }
    const items = [item_0].concat(items_1_n);
    
    if (items.some((item: any) => item === NULL_LITERAL)) {
      return NULL_EXPRESSION;
    // } else if (items.every((item: any) => item.type === 'Property')) {
    //   // every item is a key-value pair.
    //   return {
    //     type: 'ObjectExpression',
    //     properties: items,
    //   };
    // } else if (items.every((item: any) => item.type !== 'Property')) {
    //   // every item is an expression (not a key-value pair).
    //   return {
    //     type: 'ArrayExpression',
    //     elements: items,
    //   };
    } else {
    //     pushDiagnostic(location(), 'Mixture of associate-array and data-array literals not allowed.', vscode.DiagnosticSeverity.Error);
    //     return NULL_EXPRESSION;
      return {
        type: 'ObjectExpression',
        properties: items,
      }
    }
  }

/**
 * An item in array-literal, either a colon-separated pair of expressions or a single expression.
 * <NOTICE> While 'key' property must be a 'Literal' or 'Identifier' in the Parser AST,
 * <NOTICE> that of spec can be an 'Expression'.
 */
array_item =
  //  e.g., [ 1: 2: "item", 2: 3: "item2" ]
  key1:expr_multi? _0_ ':' _0_ key2:expr_multi? _0_ ':' _0_ value:expr_multi? {
    if (!key1 || !key2) {
      pushDiagnostic(location(), `Expected a key expression.`, vscode.DiagnosticSeverity.Error);
    } else if (!value) {
      pushDiagnostic(location(), `Expected a value expression.`, vscode.DiagnosticSeverity.Error);
    }
    // Not yet implemented. key2 is not exported!!!
    return {
      type: 'Property',
      key: key1 ? key1 : NULL_LITERAL,
      value: value ? value : NULL_LITERAL,
      kind: 'init',
    };
  }
  /
  //  e.g., [ 0: "item", 1: "item2" ]
  key:expr_multi? _0_ ':' _0_ value:expr_multi? {
    if (!key) {
      pushDiagnostic(location(), `Expected a key expression.`, vscode.DiagnosticSeverity.Error);
    } else if (!value) {
      pushDiagnostic(location(), `Expected a value expression.`, vscode.DiagnosticSeverity.Error);
    }
    return {
      type: 'Property',
      key: key ? key : NULL_LITERAL,
      value: value ? value : NULL_LITERAL,
      kind: 'init',
    };
  }
  / expr_multi


/**
 * <BNF> ( expression )
 * Expression in the Parser AST must not be null.
 */
expr_block 'parentheses that enclose expression' =
  '(' _0_ expr:expr_multi? _0_ closer:')'? {
    if (!expr) {
      pushDiagnostic(location(), `Expected an expression in the parentheses.`, vscode.DiagnosticSeverity.Error);
      return NULL_EXPRESSION;
    } else if (!closer) {
      pushDiagnostic(shortenRange(location(), 1), 'Unterminated parenthesis.', vscode.DiagnosticSeverity.Error);
    }
    return expr;
  }

/**
 * <BNF> function(expression-list)
 *
 * Respective arguments must be separated with a comma.
 * It seems spec does not allow string concatenation of arguments.
 */
function_call 'function call' =
  expr:strict_identifier _0_ args:(
    '(' _0_ args:expr_solo_list? _0_ closer:')'? {
      if (!closer) {
        pushDiagnostic(shortenRange(location(), 1), 'Unterminated parenthesis.', vscode.DiagnosticSeverity.Error);
      }
      return args;
    }
  ) {
    return {
      type: 'CallExpression',
      callee: expr,
      arguments: args ? args : [],
    };
  }


/**
 * <BNF> + expression
 * <BNF> - expression
 * <BNF> ! expression
 * <BNF> ~ expression
 */
unary_expr 'unary expression' =
  op:('+' / '-' / '!' / '~') _0_ arg:expr_solo? {
    if (!arg) {
      pushDiagnostic(location(), `Expected an expression following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
    }
    return {
      type: 'UnaryExpression',
      operator: op,
      argument: arg ? arg : NULL_LITERAL,
      prefix: true,
    };
  }

/**
 * <BNF> ++ lvalue
 * <BNF> −− lvalue
 * <BNF> lvalue ++
 * <BNF> lvalue −−
 */
update_expr 'update expression' =
  op:update_op _0_ arg:lvalue? {
    if (!arg) {
      pushDiagnostic(location(), `Expected an lvalue following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
    }
    return {
      type: 'UpdateExpression',
      operator: op,
      argument: arg ? arg : NULL_LITERAL,
      prefix: true,
    };
  }
  / arg:lvalue _0_ op:update_op {
    return {
      type: 'UpdateExpression',
      operator: op,
      argument: arg,
      prefix: false,
    };
  }

update_op = '++' / '--'

/**
 * <BNF> expression binop expression
 * 3rd priority: * / %
 */
expr_term3 =
  head:expr_term2 tails:(
    _0_ op:$(('*' / '/' / '%') !'=') _0_ term:expr_term2? {
      if (!term) {
        pushDiagnostic(location(), `Expected an expression following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
        term = NULL_LITERAL;
      }
      return [op, term];
    }
  )* {
    return getBinaryExpression(head, tails);
  }

/**
 * <BNF> expression binop expression
 * 4th priority: + -
 */
expr_term4 =
  head:expr_term3 tails:(
    _0_ op:$(('+' / '-') !'=') _0_ term:expr_term3? {
      if (!term) {
        pushDiagnostic(location(), `Expected an expression following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
        term = NULL_LITERAL;
      }
      return [op, term];
    }
  )* {
    return getBinaryExpression(head, tails);
  }

/**
 * <BNF> expression binop expression
 * 5th priority: << >>
 */
expr_term5 =
  head:expr_term4 tails:(
    _0_ op:$(('<<' / '>>') !'=') _0_ term:expr_term4? {
      if (!term) {
        pushDiagnostic(location(), `Expected an expression following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
        term = NULL_LITERAL;
      }
      return [op, term];
    }
  )* {
    return getBinaryExpression(head, tails);
  }

/**
 * <BNF> expression binop expression
 * 6th priority: < <= > >=
 */
expr_term6 =
  head:expr_term5 tails:(
    _0_ op:($('<' !'<' '='?) / $('>' !'>' '='?)) _0_ term:expr_term5? {
      if (!term) {
        pushDiagnostic(location(), `Expected an expression following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
        term = NULL_LITERAL;
      }
      return [op, term];
    }
  )* {
    return getBinaryExpression(head, tails);
  }

/**
 * <BNF> expression binop expression
 * 7th priority: == !=
 */
expr_term7 =
  head:expr_term6 tails:(
    _0_ op:('==' / '!=') _0_ term:expr_term6? {
      if (!term) {
        pushDiagnostic(location(), `Expected an expression following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
        term = NULL_LITERAL;
      }
      return [op, term];
    }
  )* {
    return getBinaryExpression(head, tails);
  }

/**
 * <BNF> expression binop expression
 * 8th priority: &
 */
expr_term8 =
  head:expr_term7 tails:(
    _0_ op:$('&' ![&=]) _0_ term:expr_term7? {
      if (!term) {
        pushDiagnostic(location(), `Expected an expression following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
        term = NULL_LITERAL;
      }
      return [op, term];
    }
  )* {
    return getBinaryExpression(head, tails);
  }

/**
 * <BNF> expression binop expression
 * 9th prioirity: ^
 */
expr_term9 =
  head:expr_term8 tails:(
    _0_ op:$('^' !'=') _0_ term:expr_term8? {
      if (!term) {
        pushDiagnostic(location(), `Expected an expression following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
        term = NULL_LITERAL;
      }
      return [op, term];
    }
  )* {
    return getBinaryExpression(head, tails);
  }

/**
 * <BNF> expression binop expression
 * 10th prioirity: |
 */
expr_term10 =
  head:expr_term9 tails:(
    _0_ op:$('|' ![|=]) _0_ term:expr_term9? {
      if (!term) {
        pushDiagnostic(location(), `Expected an expression following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
        term = NULL_LITERAL;
      }
      return [op, term];
    }
  )* {
    return getBinaryExpression(head, tails);
  }

/**
 * <BNF> expression binop expression
 * 11th prioirity: &&
 */
expr_term11 =
  head:expr_term10 tails:(
    _0_ op:'&&' _0_ term:expr_term10? {
      if (!term) {
        pushDiagnostic(location(), `Expected an expression following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
        term = NULL_LITERAL;
      }
      return [op, term];
    }
  )* {
    return getBinaryExpression(head, tails, 1);
  }

/**
 * <BNF> expression binop expression
 * 12th prioirity: ||
 */
expr_term12 =
  head:expr_term11 tails:(
    _0_ op:'||' _0_ term:expr_term11? {
      if (!term) {
        pushDiagnostic(location(), `Expected an expression following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
        term = NULL_LITERAL;
      }
      return [op, term];
    }
  )* {
    return getBinaryExpression(head, tails, 1);
  }

/*
 * <BNF> expression ? expression : expression
 * 13th priority: ? :
 */
expr_term13 =
  head: expr_term12 tails:(
    _0_ '?' _0_ cons:expr_term12? _0_ alt:(
      ':' _0_ alt:expr_term12? {
        return alt;
      }
    )? {
      if (!alt) {
        pushDiagnostic(location(), 'Expected an altenative expression following \":\" opearator.', vscode.DiagnosticSeverity.Error);
        alt = NULL_LITERAL;
      } else if (!cons) {
        pushDiagnostic(location(), 'Expected a consequent expression following \"?\" opearator.', vscode.DiagnosticSeverity.Error);
        cons = NULL_LITERAL;
      }
      return [cons, alt];
    }
  )* {
    return tails.reduce((accumulator: any, currentValue: any) => {
      const cons = currentValue[0];
      const alt = currentValue[1];
      return {
        type: 'ConditionalExpression',
        test: accumulator,
        left: cons,
        right: alt,
      };
    }, head);
  }

/*
 * <BNF> lvalue asgnop expression
 * 14th priority: = += -= *= /= %= &= |= ^= <<= >>=
 */
expr_term14 =
  head:expr_term13 tail:(
    _0_ op:assignment_op _0_ term:expr_multi? {
      if (!term) {
        pushDiagnostic(location(), `Expected an expression following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
        term = NULL_LITERAL;
      }
      return [op, term];
    }
  )? {
    if (!tail) {
      return head;
    } else {
      if (head.type !== 'Identifier' && head.type !== 'MemberExpression') {
        pushDiagnostic(location(), 'Left-side value must be assignable.', vscode.DiagnosticSeverity.Error);
      }
      const op = tail[0];
      const term = tail[1];
      return {
        type: 'AssignmentExpression',
        operator: op,
        left: head,
        right: term,
      };
    }
  }

assignment_op =
  $('=' !'=') / '+=' / '-=' / '*=' / '/=' / '%='
  / '<<=' / '>>=' / '&=' / '^=' / '|='

/*
 * <15th priority> in
 * <BNF> expression in assoc-array
 * 
 * Though not documented, it seems 'in' operator has lower priority than assignment operators.
 *  > myvar = "key" in assoc_array; print myvar
 * returns "key".
 */
expr_term15 =
  head:expr_term14 tails:(
    _0_ op:'in' !word _0_ term:assoc_array? {
      if (!term) {
        pushDiagnostic(location(), `Expected an associative array following \"${op}\" operator.`, vscode.DiagnosticSeverity.Error);
      }
      return [op, term];
    }
  )* {
    return getBinaryExpression(head, tails);
  }

/*
 * <The last priority> concatenation
 * <BNF> expression expression
 * 
 * expression that includes concatenation (e.g., "1" "2" yields "12")
 * Though not documented in the Grammer Rules, this rule can be
 * used in limited contexts of the expression.
 */
expr_multi =
  head:expr_solo tails:(
    spaces:_0_ term:expr_solo {
      if (!spaces || spaces.length === 0) {
        pushDiagnostic(location(), 'Expressions should be separated with whitespace.', vscode.DiagnosticSeverity.Information);
      }
      return [' ', term];
    }
  )* {
    return getBinaryExpression(head, tails);
  }

/**
 * This rule allow concatenation of the expression like expr_multi but 
 * throws an error.
 */
expr_solo_forced =
  head:expr_solo tails:(
    _0_ tail:expr_solo {
      pushDiagnostic(location(), 'Expression concatenation not allowed.', vscode.DiagnosticSeverity.Error);
      return [' ', tail];
    }
  )* {
    return getBinaryExpression(head, tails);
  }

/*
 * BNF> expression, expression
 * Though these are recursively defined as 'expression' in the Grammer Rules, 
 * the spec interpretter sometimes treats them differently.
 * For example, a = 1, b = 2 can not be used for the test expression in if-clause
 * (though it is written "if (expression) statement" in the Grammer Rules).
 */

/**
 * Comma-separated expression list in which concatenation of the expressions is not allowed.
 */
expr_solo_list 'comma-separated expression list' =
  item_0:expr_solo_forced items_1_n:_expr_solo_list_item* {
    return [item_0].concat(items_1_n);
  }
  /
  items_1_n:_expr_solo_list_item+ {
    pushDiagnostic(shortenRange(location(), 0), 'Expected an expression.', vscode.DiagnosticSeverity.Error);
    return [NULL_LITERAL].concat(items_1_n);
  }

_expr_solo_list_item =
  comma_sep item:expr_solo_forced? {
    if (!item) {
      pushDiagnostic(location(), 'Expected an expression.', vscode.DiagnosticSeverity.Error);
      return NULL_LITERAL;
    }
    return item;
  }

/**
 * Comma-separated expression list in which concatenation of the expressions is also allowed.
 */
expr_multi_list 'comma-separated expression list' =
  item_0:expr_multi items_1_n:_expr_multi_list_item* {
    return [item_0].concat(items_1_n);
  }
  /
  items_1_n:_expr_multi_list_item+ {
    pushDiagnostic(shortenRange(location(), 0), 'Expected an expression.', vscode.DiagnosticSeverity.Error);
    return [NULL_LITERAL].concat(items_1_n);
  }

_expr_multi_list_item =
  comma_sep item:expr_multi? {
    if (!item) {
      pushDiagnostic(location(), 'Expected an expression.', vscode.DiagnosticSeverity.Error);
      return NULL_LITERAL;
    }
    return item;
  }
