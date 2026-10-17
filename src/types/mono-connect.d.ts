// Mono Connect's widget ships without types.
declare module '@mono.co/connect.js' {
  interface ConnectOptions {
    key: string;
    scope?: 'auth' | 'payments';
    data?: { customer: { id?: string; name?: string; email?: string } };
    reference?: string;
    onSuccess: (data: { code: string }) => void;
    onClose?: () => void;
    onLoad?: () => void;
    onEvent?: (eventName: string, data: unknown) => void;
  }
  export default class Connect {
    constructor(options: ConnectOptions);
    setup(config?: Record<string, unknown>): void;
    reauthorise(accountId: string): void;
    open(): void;
    close(): void;
  }
}
