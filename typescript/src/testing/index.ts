/**
 * The fakes this package tests itself with, for applications to test with
 * too. Import them from `@37signals/actioncable/testing`; nothing here is
 * pulled into a production bundle.
 */
export { FakeConnection, FakeTransport, type FakeCommand } from "./fake-transport.js";
