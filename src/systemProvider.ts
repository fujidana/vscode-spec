import * as vscode from 'vscode';
import { TextDecoder } from "util";
import * as spec from "./spec";
import { Provider } from "./provider";

interface APIReference {
	constants: spec.ReferenceItem[];
	variables: spec.ReferenceItem[];
	functions: spec.ReferenceItem[];
	macros: spec.ReferenceItem[];
	keywords: spec.ReferenceItem[];
}

const SNIPPET_TEMPLATES: string[] = [
	'mv ${1|%s|} ${2:pos}',
	'mvr ${1|%s|} ${2:pos}',
	'ascan ${1|%s|} ${2:begin} ${3:end} ${4:steps} ${5:sec}',
	'dscan ${1|%s|} ${2:begin} ${3:end} ${4:steps} ${5:sec}',
	'a2scan ${1|%s|} ${2:begin1} ${3:end1} ${4|%s|} ${5:begin2} ${6:end2} ${7:steps} ${8:sec}',
	'd2scan ${1|%s|} ${2:begin1} ${3:end1} ${4|%s|} ${5:begin2} ${6:end2} ${7:steps} ${8:sec}',
	'mesh ${1|%s|} ${2:begin1} ${3:end1} ${4:step1} ${5|%s|} ${6:begin2} ${7:end2} ${8:steps2} ${9:sec}',
	'a3scan ${1|%s|} ${2:begin1} ${3:end1} ${4|%s|} ${5:begin2} ${6:end2} ${7|%s|} ${8:begin3} ${9:end3} ${10:steps} ${11:sec}',
	'd3scan ${1|%s|} ${2:begin1} ${3:end1} ${4|%s|} ${5:begin2} ${6:end2} ${7|%s|} ${8:begin3} ${9:end3} ${10:steps} ${11:sec}',
];

const SNIPPET_DESCRIPTIONS: string[] = [
	'absolute-position motor move',
	'relative-position motor move',
	'single-motor absolute-position scan',
	'single-motor relative-position scan',
	'two-motor absolute-position scan',
	'two-motor relative-position scan',
	'nested two-motor scan that scanned over a grid of points',
	'three-motor absolute-position scan',
	'three-motor relative-position scan',
];

/**
 * Provider for symbols that spec system manages.
 * This class manages built-in symbols and motor mnemonics user added in VS Code configuraion.
 */
export class SystemProvider extends Provider implements vscode.TextDocumentContentProvider {
	private mnemonicEnumRefMap = new spec.ReferenceMap();
	private mnemonicSnippetRefMap = new spec.ReferenceMap();

	constructor(apiReferencePath: string) {
		super();

		// load the API reference file
		vscode.workspace.fs.readFile(vscode.Uri.file(apiReferencePath)).then(uint8Array => {
			// convert JSON-formatted file contents to a javascript object.
			const apiReference: APIReference = JSON.parse(new TextDecoder('utf-8').decode(uint8Array));

			// convert the object to ReferenceMap and register the set.
			const builtinStorage = new spec.ReferenceStorage();
			builtinStorage.set(spec.ReferenceItemKind.Constant, new spec.ReferenceMap(Object.entries(apiReference.constants)));
			builtinStorage.set(spec.ReferenceItemKind.Variable, new spec.ReferenceMap(Object.entries(apiReference.variables)));
			builtinStorage.set(spec.ReferenceItemKind.Macro, new spec.ReferenceMap(Object.entries(apiReference.macros)));
			builtinStorage.set(spec.ReferenceItemKind.Function, new spec.ReferenceMap(Object.entries(apiReference.functions)));
			builtinStorage.set(spec.ReferenceItemKind.Keyword, new spec.ReferenceMap(Object.entries(apiReference.keywords)));
			this.storageCollection.set(spec.BUILTIN_URI, builtinStorage);
			this.updateCompletionItemsForUriString(spec.BUILTIN_URI);
		});

		// register motor-mnemonic storage
		const motorStorage = new spec.ReferenceStorage();
		motorStorage.set(spec.ReferenceItemKind.Enum, this.mnemonicEnumRefMap);
		motorStorage.set(spec.ReferenceItemKind.Snippet, this.mnemonicSnippetRefMap);
		this.storageCollection.set(spec.MOTOR_URI, motorStorage);
		this.updateMotorMnemonicsStorage();

		// observe the change in configuration
		vscode.workspace.onDidChangeConfiguration(event => {
			if (event.affectsConfiguration('spec.mnemonics.motor')) {
				this.updateMotorMnemonicsStorage();
			}
		});

		// register command to show reference manual as a virtual document
		vscode.commands.registerCommand('spec.open-document.built-in', async () => {
			const storage = this.storageCollection.get(spec.BUILTIN_URI);
			if (storage) {
				let quickPickLabels = ['all'];
				for (const itemKind of storage.keys()) {
					quickPickLabels.push(spec.getStringFromReferenceItemKind(itemKind));
				}
				const quickPickLabel = await vscode.window.showQuickPick(quickPickLabels);
				if (quickPickLabel) {
					let uri = vscode.Uri.parse(spec.BUILTIN_URI);
					if (quickPickLabel !== 'all') {
						uri = uri.with({ query: quickPickLabel });
					}
					await vscode.window.showTextDocument(uri, { preview: false });
				}
			}
		});
	}

	/**
	 * Update the contents of motor-mnemonic storage.
	 * Invoked when initialization completed or configuration modified. 
	 */
	private updateMotorMnemonicsStorage() {
		const motorConfig = vscode.workspace.getConfiguration('spec.mnemonics.motor');
		const mneLabels: string[] = motorConfig.get('labels', []);
		const mneDescriptions: string[] = motorConfig.get('descriptions', []);

		// refresh storages related to motor mnemonic, which is configured in the settings.
		this.mnemonicEnumRefMap.clear();
		this.mnemonicSnippetRefMap.clear();

		if (mneLabels.length > 0) {
			// refresh storage for motor mnemonic label
			for (let index = 0; index < mneLabels.length; index++) {
				const mneLabel = mneLabels[index];
				const mneDescription = (mneDescriptions.length > index) ? mneDescriptions[index] : undefined;
				this.mnemonicEnumRefMap.set(mneLabel, { signature: mneLabel, description: mneDescription });
			}

			// refresh storage for motor mnemonic macro (snippet)
			for (let index = 0; index < SNIPPET_TEMPLATES.length; index++) {
				const snippetTemplate = SNIPPET_TEMPLATES[index];
				const snippetDesription = (SNIPPET_DESCRIPTIONS.length > index) ? SNIPPET_DESCRIPTIONS[index] : undefined;

				// treat the first word of the template as the snippet key.
				const offset = snippetTemplate.indexOf(' ');
				if (offset < 0) {
					console.log('Unexpected Snippet Format:', snippetTemplate);
					continue;
				}
				const snippetKey = snippetTemplate.substring(0, offset);

				// check the necessary number of motors. If not satisfied, skip the template.
				const minMotor = snippetTemplate.match(/%s/g);
				if (minMotor === null) {
					console.log('Unexpected Snippet Format:', snippetTemplate);
					continue;
				}
				if (minMotor.length > mneLabels.length) {
					continue;
				}

				// reformat the information.
				const snippetSignature = snippetTemplate.replace(/\$\{\d+:([^}]*)\}/g, '$1').replace(/\$\{\d+\|%s\|\}/g, mneLabels[0]);
				const snippetCode = snippetTemplate.replace(/%s/g, mneLabels.join(','));

				this.mnemonicSnippetRefMap.set(snippetKey, { signature: snippetSignature, description: snippetDesription, snippet: snippetCode });
			}
		}

		this.updateCompletionItemsForUriString(spec.MOTOR_URI);
	}

	/**
	 * required implementation of vscode.TextDocumentContentProvider
	 */
	public provideTextDocumentContent(uri: vscode.Uri, token: vscode.CancellationToken): vscode.ProviderResult<string> {
		if (uri.scheme === 'spec' && uri.authority === 'system') {
			const storage = this.storageCollection.get(uri.with({ query: '' }).toString());
			if (storage) {
				let mdText = '# __spec__ Reference Manual\n\n';
				mdText += 'The contents of this page are cited from the _Reference Manual_ section in [PDF version](https://www.certif.com/downloads/css_docs/spec_man.pdf) of the _User manual and Tutorials_, written by [Certified Scientific Software](https://www.certif.com/).\n\n';

				for (const [itemKind, map] of storage.entries()) {
					const itemKindString = spec.getStringFromReferenceItemKind(itemKind);

					// if 'query' is specified, skip maps other than the speficed query.
					if (uri.query && uri.query !== itemKindString) {
						continue;
					}

					// add heading for each category
					mdText += `## ${itemKindString}\n\n`;

					// add each item
					for (const [key, item] of map.entries()) {
						mdText += `### ${key}\n\n`;
						mdText += `\`${item.signature}\``;
						mdText += (item.description) ? ` \u2014 ${item.description}\n\n` : '\n\n';

						if (item.overloads) {
							for (const overload of item.overloads) {
								mdText += `\`${overload.signature}\``;
								mdText += (overload.description) ? `\n${overload.description}\n\n` : '\n\n';
							}
						}
					}
				}
				return mdText;
			}
		}
	}
}