import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

interface AssetManifest {
  version: string;
  files: Array<string>;
}

/** Materialize the packaged data before the native engine opens its files. */
export class GameAssets {
  private static makeDirectory(path: string): void {
    if (!fs.accessSync(path)) {
      fs.mkdirSync(path, true);
    }
  }

  private static writeFile(path: string, content: Uint8Array): void {
    const file: fs.File = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      let offset: number = 0;
      while (offset < content.byteLength) {
        const buffer: ArrayBuffer = content.buffer.slice(content.byteOffset + offset,
          content.byteOffset + content.byteLength) as ArrayBuffer;
        const written: number = fs.writeSync(file.fd, buffer);
        if (written <= 0) {
          throw new Error('Unable to write game resources');
        }
        offset += written;
      }
    } finally {
      fs.closeSync(file);
    }
  }

  static async prepare(context: common.UIAbilityContext): Promise<string> {
    const root: string = `${context.filesDir}/openttd`;
    const data: string = `${root}/data`;
    const staging: string = `${root}/data.next`;
    const previous: string = `${root}/data.previous`;
    GameAssets.makeDirectory(root);
    const bytes: Uint8Array = await context.resourceManager.getRawFileContent('openttd-assets.json');
    const manifest: AssetManifest = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(bytes)) as AssetManifest;
    if (!manifest.version || manifest.files.length === 0) {
      throw new Error('The game resource manifest is empty');
    }
    // Recover a swap interrupted by process termination.
    if (!fs.accessSync(data) && fs.accessSync(previous)) {
      fs.renameSync(previous, data);
    }
    const stamp: string = `${data}/.assets-version`;
    if (fs.accessSync(stamp) && fs.readTextSync(stamp) === manifest.version &&
      manifest.files.every((name: string): boolean => fs.accessSync(`${data}/${name}`))) {
      return root;
    }
    if (fs.accessSync(staging)) {
      fs.rmdirSync(staging);
    }
    GameAssets.makeDirectory(staging);
    for (const name of manifest.files) {
      if (name.startsWith('/') || name.split('/').includes('..')) {
        throw new Error('Invalid resource path');
      }
      const path: string = `${staging}/${name}`;
      GameAssets.makeDirectory(path.substring(0, path.lastIndexOf('/')));
      const content: Uint8Array = await context.resourceManager.getRawFileContent(name);
      GameAssets.writeFile(path, content);
    }
    GameAssets.writeFile(`${staging}/.assets-version`, util.TextEncoder.create('utf-8').encodeInto(manifest.version));
    if (fs.accessSync(previous)) {
      fs.rmdirSync(previous);
    }
    if (fs.accessSync(data)) {
      fs.renameSync(data, previous);
    }
    try {
      fs.renameSync(staging, data);
    } catch (error) {
      if (fs.accessSync(previous)) {
        fs.renameSync(previous, data);
      }
      throw new Error(`Unable to activate game resources: ${JSON.stringify(error)}`);
    }
    if (fs.accessSync(previous)) {
      fs.rmdirSync(previous);
    }
    // Saves, configuration and downloaded content live outside these data directories.
    return root;
  }
}
