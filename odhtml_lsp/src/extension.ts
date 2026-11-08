import * as path from 'path';
import * as fs from 'fs';
import { ExtensionContext, workspace, commands, window, OutputChannel } from 'vscode';
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;
let outputChannel: OutputChannel | undefined;

function findServerBinary(context: ExtensionContext): string | undefined {
  const config = workspace.getConfiguration('odhtml');
  const customPath = config.get<string>('serverPath');
  if (customPath && fs.existsSync(customPath)) {
    return customPath;
  }

  const binaryName = process.platform === 'win32' ? 'odhtml-lsp.exe' : 'odhtml-lsp';

  // 1. Check workspace output/ and odhtml_lsp/ folders
  if (workspace.workspaceFolders) {
    for (const folder of workspace.workspaceFolders) {
      const candidate = path.join(folder.uri.fsPath, 'output', binaryName);
      if (fs.existsSync(candidate)) {
        return candidate;
      }
      const candidateLocal = path.join(folder.uri.fsPath, 'odhtml_lsp', binaryName);
      if (fs.existsSync(candidateLocal)) {
        return candidateLocal;
      }
    }
  }

  // 2. Check active editor document folder and parent directories
  const activeDoc = window.activeTextEditor?.document;
  if (activeDoc && activeDoc.uri.scheme === 'file') {
    let curr = path.dirname(activeDoc.uri.fsPath);
    for (let i = 0; i < 5; i++) {
      const cand = path.join(curr, 'output', binaryName);
      if (fs.existsSync(cand)) return cand;
      const parent = path.dirname(curr);
      if (parent === curr) break;
      curr = parent;
    }
  }

  // 3. Global tool directory (e.g. C:\tools\odhtml or ~/.local/bin)
  const globalDirs = process.platform === 'win32'
    ? [
        path.join('C:', 'tools', 'odhtml', binaryName),
        path.join(process.env.LOCALAPPDATA || '', 'odhtml', binaryName),
      ]
    : [
        path.join(process.env.HOME || '', '.local', 'bin', binaryName),
        path.join('/usr', 'local', 'bin', binaryName),
      ];

  for (const gPath of globalDirs) {
    if (gPath && fs.existsSync(gPath)) {
      return gPath;
    }
  }

  // 4. System PATH
  const pathDirs = (process.env.PATH || '').split(path.delimiter);
  for (const dir of pathDirs) {
    const candidate = path.join(dir, binaryName);
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  // 5. Bundled fallback directly inside this VS Code extension package
  const bundled = context.asAbsolutePath(binaryName);
  if (fs.existsSync(bundled)) {
    return bundled;
  }

  return undefined;
}

export function activate(context: ExtensionContext) {
  outputChannel = window.createOutputChannel('odhtml Language Server');
  outputChannel.appendLine('[odhtml] Extension activating...');

  const binaryPath = findServerBinary(context);
  if (!binaryPath) {
    const msg = "Could not find 'odhtml-lsp' executable. Run 'build.bat' or set 'odhtml.serverPath' in Settings.";
    outputChannel.appendLine(`[odhtml] ERROR: ${msg}`);
    window.showErrorMessage(msg);
    return;
  }

  outputChannel.appendLine(`[odhtml] Found server binary at: ${binaryPath}`);

  const serverOptions: ServerOptions = {
    command: binaryPath,
    args: [],
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: 'file', language: 'odhtml' }],
    synchronize: {
      fileEvents: workspace.createFileSystemWatcher('**/*.odhtml'),
    },
    outputChannel: outputChannel,
  };

  client = new LanguageClient(
    'odhtmlLanguageServer',
    'odhtml Language Server (Native Odin)',
    serverOptions,
    clientOptions
  );

  client.start().then(() => {
    outputChannel?.appendLine('[odhtml] Language Server started and ready.');
  }).catch((err) => {
    outputChannel?.appendLine(`[odhtml] Failed to start Language Server: ${err}`);
    window.showErrorMessage(`odhtml Language Server failed to start: ${err}`);
  });

  context.subscriptions.push(
    commands.registerCommand('odhtml.restartServer', async () => {
      if (client) {
        outputChannel?.appendLine('[odhtml] Restarting Language Server...');
        await client.stop();
        client.start().then(() => {
          outputChannel?.appendLine('[odhtml] Language Server restarted successfully.');
          window.showInformationMessage('odhtml Language Server restarted.');
        });
      }
    })
  );
}

export function deactivate(): Thenable<void> | undefined {
  if (!client) {
    return undefined;
  }
  return client.stop();
}
