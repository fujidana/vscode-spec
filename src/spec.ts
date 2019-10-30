import * as vscode from 'vscode';

interface PegPosition {
	offset: number;
	line: number;
	column: number;
}
interface PegRange {
	start: PegPosition;
	end: PegPosition;
}
export function convertPosition(pesPosition: PegPosition) {
	return new vscode.Position(pesPosition.line - 1, pesPosition.column - 1);
}
export function convertRange(pesRange: PegRange) {
	return new vscode.Range(convertPosition(pesRange.start), convertPosition(pesRange.end));
}
export const BUILTIN_URI = 'spec://system/built-in.md';
export const MOTOR_URI = 'spec://system/mnemonic-motor.md';
export const ACTIVE_FILE_URI = 'spec://user/active-document.md';

export const enum ReferenceItemKind {
	Undefined = 0,
	Constant,
	Variable,
	Macro,
	Function,
	Keyword,
	Snippet,
	Enum,
}

export function getReferenceItemKindFromCompletionItemKind(completionItemKind?: vscode.CompletionItemKind): ReferenceItemKind {
	switch (completionItemKind) {
		case vscode.CompletionItemKind.Constant:
			return ReferenceItemKind.Constant;
		case vscode.CompletionItemKind.Variable:
			return ReferenceItemKind.Variable;
		case vscode.CompletionItemKind.Function:
			return ReferenceItemKind.Macro;
		case vscode.CompletionItemKind.Method:
			return ReferenceItemKind.Function;
		case vscode.CompletionItemKind.Keyword:
			return ReferenceItemKind.Keyword;
		case vscode.CompletionItemKind.Snippet:
			return ReferenceItemKind.Snippet;
		case vscode.CompletionItemKind.EnumMember:
			return ReferenceItemKind.Enum;
		default:
			return ReferenceItemKind.Undefined;
	}
}
export function getCompletionItemKindFromReferenceItemKind(refItemKind: ReferenceItemKind): vscode.CompletionItemKind | undefined {
	switch (refItemKind) {
		case ReferenceItemKind.Constant:
			return vscode.CompletionItemKind.Constant;
		case ReferenceItemKind.Variable:
			return vscode.CompletionItemKind.Variable;
		case ReferenceItemKind.Macro:
			return vscode.CompletionItemKind.Function;
		case ReferenceItemKind.Function:
			return vscode.CompletionItemKind.Method;
		case ReferenceItemKind.Keyword:
			return vscode.CompletionItemKind.Keyword;
		case ReferenceItemKind.Snippet:
			return vscode.CompletionItemKind.Snippet;
		case ReferenceItemKind.Enum:
			return vscode.CompletionItemKind.EnumMember;
		case ReferenceItemKind.Undefined:
			return undefined;
		default:
			return undefined;
	}
}

export function getSymbolKindFromReferenceItemKind(refItemKind: ReferenceItemKind): vscode.SymbolKind {
	switch (refItemKind) {
		case ReferenceItemKind.Constant:
			return vscode.SymbolKind.Constant;
		case ReferenceItemKind.Variable:
			return vscode.SymbolKind.Variable;
		case ReferenceItemKind.Macro:
			return vscode.SymbolKind.Function;
		case ReferenceItemKind.Function:
			return vscode.SymbolKind.Method;
		// case ReferenceItemKind.Keyword:
		// case ReferenceItemKind.Snippet:
		case ReferenceItemKind.Enum:
			return vscode.SymbolKind.EnumMember;
		case ReferenceItemKind.Undefined:
			return vscode.SymbolKind.Null;
		default:
			return vscode.SymbolKind.Null;
	}
}

export function getStringFromReferenceItemKind(refItemKind: ReferenceItemKind): string {
	switch (refItemKind) {
		case ReferenceItemKind.Constant:
			return "constant";
		case ReferenceItemKind.Variable:
			return "variable";
		case ReferenceItemKind.Macro:
			return "macro";
		case ReferenceItemKind.Function:
			return "function";
		case ReferenceItemKind.Keyword:
			return "keyword";
		case ReferenceItemKind.Snippet:
			return "snippet";
		case ReferenceItemKind.Enum:
			return "member";
		default:
			return "symbol";
	}
}

// 'overloads' parameter is for built-in macros and functions.
export interface ReferenceItem {
	signature: string;
	description?: string;
	snippet?: string;
	location?: PegRange;
	overloads?: Overload[];
}

export interface Overload {
	signature: string;
	description?: string;
}

export class ReferenceMap extends Map<string, ReferenceItem> { }

export class ReferenceStorage extends Map<ReferenceItemKind, ReferenceMap> { }