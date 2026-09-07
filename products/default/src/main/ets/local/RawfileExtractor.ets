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
    RawfileExtractor.writeSignature(context, destRoot);
  }

  /**
   * True when the extracted copy in the sandbox matches the current shipped
   * rawfile assets. A shallow signature is compared - the hashes of the small
   * integration files (prelude.js, index.html) plus the element-web bundle
   * hash directory name - so that `install -r` deploys over an older
   * extraction still refresh the served files when anything we ship changed.
   */
  static async isCurrent(context: common.UIAbilityContext, destRoot: string): Promise<boolean> {
    try {
      const marker: string = destRoot + '/.extracted';
      if (!fileIo.accessSync(marker)) {
        return false;
      }
      const f = fileIo.openSync(marker, fileIo.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(512);
      const n = fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f.fd);
      const u8 = new Uint8Array(buf).slice(0, n);
      let stored: string = '';
      for (let i = 0; i < u8.length; i++) {
        stored += String.fromCharCode(u8[i]);
      }
      return stored === RawfileExtractor.signature(context, destRoot);
    } catch (e) {
      return false;
    }
  }

  private static writeSignature(context: common.UIAbilityContext, destRoot: string): void {
    try {
      const sig: string = RawfileExtractor.signature(context, destRoot);
      const bytes = new Uint8Array(sig.length);
      for (let i = 0; i < sig.length; i++) {
        bytes[i] = sig.charCodeAt(i) & 0xff;
      }
      const marker: string = destRoot + '/.extracted';
      const f = fileIo.openSync(marker,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, bytes.buffer.slice(0, bytes.byteLength));
      fileIo.closeSync(f.fd);
    } catch (e) {
      // ignore - a missing marker simply forces a re-extraction next start
    }
  }

  private static signature(context: common.UIAbilityContext, destRoot: string): string {
    const prelude: string = RawfileExtractor.fnv1a(context.resourceManager.getRawFileContentSync('element/prelude.js'));
    const index: string = RawfileExtractor.fnv1a(context.resourceManager.getRawFileContentSync('element/index.html'));
    let rawBundles: Array<string> = [];
    try {
      rawBundles = context.resourceManager.getRawFileListSync('element/bundles').sort();
    } catch (e) {
      rawBundles = [];
    }
    let sandBundles: Array<string> = [];
    try {
      sandBundles = fileIo.listFileSync(destRoot + '/bundles').sort();
    } catch (e) {
      sandBundles = [];
    }
    return prelude + '-' + index + '-' + rawBundles.join(',') + '-' + sandBundles.join(',');
  }

  private static fnv1a(data: Uint8Array): string {
    let hash: number = 0x811c9dc5;
    for (let i = 0; i < data.length; i++) {
      hash ^= data[i];
      hash = (hash * 16777619) >>> 0;
    }
    return hash.toString(16);
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
}