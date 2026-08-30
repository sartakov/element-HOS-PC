import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';

export class RawfileExtractor {
  static async copyToSandbox(context: common.UIAbilityContext, rawRoot: string, destRoot: string): Promise<void> {
    try {
      fileIo.mkdirSync(destRoot, true);
    } catch (e) {
      // ignore if already exists
    }
    await RawfileExtractor.copyDir(context, rawRoot, destRoot);
    const marker: string = destRoot + '/.extracted';
    const f = fileIo.openSync(marker,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, new ArrayBuffer(0));
    fileIo.closeSync(f.fd);
  }

  private static async copyDir(context: common.UIAbilityContext, rawDir: string, destDir: string): Promise<void> {
    try {
      fileIo.mkdirSync(destDir, true);
    } catch (e) {
      // ignore if already exists
    }
    let entries: Array<string> = [];
    try {
      entries = await context.resourceManager.getRawFileList(rawDir);
    } catch (e) {
      return;
    }
    for (let i = 0; i < entries.length; i++) {
      const name: string = entries[i];
      const relPath: string = rawDir + '/' + name;
      const destPath: string = destDir + '/' + name;
      let wroteFile: boolean = false;
      try {
        const content: Uint8Array = await context.resourceManager.getRawFileContent(relPath);
        const file = fileIo.openSync(destPath,
          fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, content.buffer.slice(0, content.byteLength));
        fileIo.closeSync(file.fd);
        wroteFile = true;
      } catch (e) {
        // likely a directory entry; fall through to recursion below
      }
      if (!wroteFile) {
        try {
          await RawfileExtractor.copyDir(context, relPath, destPath);
        } catch (e) {
          // ignore a single failing directory
        }
      }
    }
  }

  static async isExtracted(rootDir: string): Promise<boolean> {
    try {
      const path: string = rootDir + '/.extracted';
      return fileIo.accessSync(path);
    } catch (e) {
      return false;
    }
  }
}
