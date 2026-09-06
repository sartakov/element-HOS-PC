import { socket } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const CRLF: string = '\r\n';
const FIXED_PORT: number = 8448;
const MAX_BIND_ATTEMPTS: number = 10;
const BIND_RETRY_DELAY_MS: number = 500;
const DOMAIN = 0x0000;
const TAG = 'LocalHttpServer';

export class LocalHttpServer {
  private rootDir: string;
  private server: socket.TCPSocketServer | null = null;
  private baseUrl: string = '';

  constructor(rootDir: string) {
    this.rootDir = rootDir;
  }

  async start(): Promise<string> {
    let srv: socket.TCPSocketServer | null = null;
    let boundPort: number = -1;
    for (let attempt = 0; attempt < MAX_BIND_ATTEMPTS; attempt++) {
      srv = socket.constructTCPSocketServerInstance();
      this.server = srv;
      try {
        await srv.listen({ address: '127.0.0.1', port: FIXED_PORT, family: 1 });
        await new Promise<void>((resolve) => {
          setTimeout(() => {
            resolve();
          }, 100);
        });
        const localAddr: socket.NetAddress = await srv.getLocalAddress();
        boundPort = localAddr.port ?? -1;
        if (boundPort === FIXED_PORT) {
          break;
        }
        // The SDK silently falls back to a random port when the fixed port is
        // busy. A different port changes the page origin, which orphans the
        // IndexedDB login session and forces a re-login. Close and retry so the
        // origin (and the session) stays stable across relaunches.
        hilog.warn(DOMAIN, TAG, 'Port %{public}d busy, got %{public}d; retrying', FIXED_PORT, boundPort);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'listen on %{public}d failed: %{public}s; retrying', FIXED_PORT, JSON.stringify(e));
      }
      if (srv !== null) {
        try {
          await srv.close();
        } catch (e) {
          // ignore close errors
        }
        srv = null;
        this.server = null;
      }
      await new Promise<void>((resolve) => {
        setTimeout(() => {
          resolve();
        }, BIND_RETRY_DELAY_MS);
      });
    }
    if (srv === null || boundPort !== FIXED_PORT) {
      throw new Error(`Unable to bind fixed port ${FIXED_PORT}`);
    }
    this.baseUrl = `http://127.0.0.1:${boundPort}`;
    srv.on('connect', (connection: socket.TCPSocketConnection) => {
      this.handleConnection(connection);
    });
    return this.baseUrl;
  }

  async stop(): Promise<void> {
    if (this.server !== null) {
      try {
        await this.server.close();
      } catch (e) {
        // ignore close errors
      }
      this.server = null;
    }
  }

  private handleConnection(connection: socket.TCPSocketConnection): void {
    let buffer: Uint8Array = new Uint8Array(0);
    connection.on('message', (info: socket.SocketMessageInfo) => {
      try {
        const msg: ArrayBuffer = info.message;
        const chunk: Uint8Array = new Uint8Array(msg.byteLength);
        chunk.set(new Uint8Array(msg));
        const combined: Uint8Array = new Uint8Array(buffer.length + chunk.length);
        combined.set(buffer, 0);
        combined.set(chunk, buffer.length);
        buffer = combined;
        const headerEnd: number = this.findHeaderEnd(buffer);
        if (headerEnd >= 0) {
          const headerStr: string = this.decodeUtf8(buffer.subarray(0, headerEnd));
          buffer = new Uint8Array(0);
          this.processRequest(connection, headerStr).catch(() => {
            // ignore
          });
        }
      } catch (e) {
        // ignore per-connection errors
      }
    });
  }

  private findHeaderEnd(buffer: Uint8Array): number {
    for (let i = 0; i < buffer.length - 3; i++) {
      if (buffer[i] === 13 && buffer[i + 1] === 10 && buffer[i + 2] === 13 && buffer[i + 3] === 10) {
        return i;
      }
    }
    return -1;
  }

  private decodeUtf8(bytes: Uint8Array): string {
    const decoder: util.TextDecoder = new util.TextDecoder('utf-8');
    return decoder.decode(bytes);
  }

  private encodeUtf8(str: string): Uint8Array {
    const encoder: util.TextEncoder = new util.TextEncoder();
    return encoder.encode(str);
  }

  private toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
    return bytes.buffer.slice(0, bytes.byteLength);
  }

  private async processRequest(connection: socket.TCPSocketConnection, header: string): Promise<void> {
    try {
      const lines: string[] = header.split(CRLF);
      if (lines.length === 0) {
        return;
      }
      const requestLine: string = lines[0];
      const parts: string[] = requestLine.split(' ');
      if (parts.length < 2) {
        return;
      }
      const method: string = parts[0];
      const rawPath: string = parts[1];
      const headOnly: boolean = method === 'HEAD';
      if (method !== 'GET' && method !== 'HEAD') {
        await this.sendResponse(connection, 405, 'Method Not Allowed', 'text/plain',
          this.toArrayBuffer(this.encodeUtf8('Method Not Allowed')), headOnly);
        return;
      }
      const filePath: string | null = this.resolvePath(rawPath);
      if (filePath === null) {
        await this.sendResponse(connection, 403, 'Forbidden', 'text/plain',
          this.toArrayBuffer(this.encodeUtf8('Forbidden')), headOnly);
        return;
      }
      const body: ArrayBuffer | null = this.readFile(filePath);
      if (body === null) {
        await this.sendResponse(connection, 404, 'Not Found', 'text/plain',
          this.toArrayBuffer(this.encodeUtf8('Not Found')), headOnly);
        return;
      }
      const mime: string = this.mimeType(filePath);
      await this.sendResponse(connection, 200, 'OK', mime, body, headOnly);
    } catch (e) {
      // ignore
    }
  }

  private async sendResponse(connection: socket.TCPSocketConnection, status: number, reason: string,
    contentType: string, body: ArrayBuffer, headOnly: boolean): Promise<void> {
    const header: string =
      `HTTP/1.1 ${status} ${reason}${CRLF}` +
      `Content-Type: ${contentType}${CRLF}` +
      `Content-Length: ${body.byteLength}${CRLF}` +
      `Connection: close${CRLF}` +
      `Access-Control-Allow-Origin: *${CRLF}` +
      CRLF;
    const headerBytes: Uint8Array = this.encodeUtf8(header);
    await connection.send({ data: this.toArrayBuffer(headerBytes) });
    if (!headOnly && body.byteLength > 0) {
      await connection.send({ data: body });
    }
    try {
      await connection.close();
    } catch (e) {
      // ignore
    }
  }

  private readFile(path: string): ArrayBuffer | null {
    try {
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(path);
      const len: number = stat.size;
      const buffer: ArrayBuffer = new ArrayBuffer(len);
      let bytesRead: number = 0;
      while (bytesRead < len) {
        const n: number = fileIo.readSync(file.fd, buffer, {
          offset: bytesRead,
          length: len - bytesRead
        });
        if (n <= 0) {
          break;
        }
        bytesRead += n;
      }
      fileIo.closeSync(file.fd);
      if (bytesRead < len) {
        return buffer.slice(0, bytesRead);
      }
      return buffer;
    } catch (e) {
      return null;
    }
  }

  private resolvePath(rawPath: string): string | null {
    let path: string = rawPath;
    const qIndex: number = path.indexOf('?');
    if (qIndex >= 0) {
      path = path.substring(0, qIndex);
    }
    path = this.percentDecode(path);
    if (path.length === 0 || path === '/') {
      path = '/index.html';
    }
    const segments: string[] = path.split('/');
    const resolved: string[] = [];
    for (let i = 0; i < segments.length; i++) {
      const seg: string = segments[i];
      if (seg.length === 0 || seg === '.') {
        continue;
      }
      if (seg === '..') {
        if (resolved.length > 0) {
          resolved.pop();
        }
        continue;
      }
      resolved.push(seg);
    }
    const relPath: string = resolved.join('/');
    const fullPath: string = this.rootDir + '/' + relPath;
    if (!fullPath.startsWith(this.rootDir + '/')) {
      return null;
    }
    return fullPath;
  }

  private percentDecode(input: string): string {
    const bytes: number[] = [];
    let i: number = 0;
    while (i < input.length) {
      const c: string = input.charAt(i);
      if (c === '%' && i + 2 < input.length) {
        const hex: string = input.substring(i + 1, i + 3);
        const code: number = parseInt(hex, 16);
        if (!isNaN(code)) {
          bytes.push(code);
          i += 3;
          continue;
        }
      }
      const codePoint: number = c.charCodeAt(0);
      if (codePoint < 0x80) {
        bytes.push(codePoint);
      } else if (codePoint < 0x800) {
        bytes.push(0xC0 | (codePoint >> 6));
        bytes.push(0x80 | (codePoint & 0x3F));
      } else {
        bytes.push(0xE0 | (codePoint >> 12));
        bytes.push(0x80 | ((codePoint >> 6) & 0x3F));
        bytes.push(0x80 | (codePoint & 0x3F));
      }
      i++;
    }
    const arr: Uint8Array = new Uint8Array(bytes.length);
    for (let j = 0; j < bytes.length; j++) {
      arr[j] = bytes[j];
    }
    return this.decodeUtf8(arr);
  }

  private mimeType(path: string): string {
    const dot: number = path.lastIndexOf('.');
    if (dot < 0) {
      return 'application/octet-stream';
    }
    const ext: string = path.substring(dot + 1).toLowerCase();
    const map: Map<string, string> = new Map<string, string>();
    map.set('html', 'text/html');
    map.set('js', 'application/javascript');
    map.set('css', 'text/css');
    map.set('json', 'application/json');
    map.set('png', 'image/png');
    map.set('jpg', 'image/jpeg');
    map.set('jpeg', 'image/jpeg');
    map.set('gif', 'image/gif');
    map.set('svg', 'image/svg+xml');
    map.set('wasm', 'application/wasm');
    map.set('woff', 'font/woff');
    map.set('woff2', 'font/woff2');
    map.set('otf', 'font/otf');
    map.set('eot', 'application/vnd.ms-fontobject');
    map.set('ttf', 'font/ttf');
    map.set('map', 'application/json');
    map.set('ico', 'image/x-icon');
    map.set('mp3', 'audio/mpeg');
    map.set('ogg', 'audio/ogg');
    map.set('mp4', 'video/mp4');
    map.set('txt', 'text/plain');
    map.set('xml', 'application/xml');
    map.set('webp', 'image/webp');
    map.set('m4a', 'audio/mp4');
    map.set('flac', 'audio/flac');
    map.set('wav', 'audio/wav');
    map.set('webm', 'video/webm');
    map.set('pdf', 'application/pdf');
    map.set('zip', 'application/zip');
    map.set('gz', 'application/gzip');
    const mime: string | undefined = map.get(ext);
    if (mime !== undefined) {
      return mime;
    }
    return 'application/octet-stream';
  }
}
