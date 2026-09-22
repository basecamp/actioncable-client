/// The release this client shipped in, one number across every language in the
/// repository.
///
/// The module's types are all top level — `ActionCableClient`, `Subscription`,
/// `Identifier` and the rest — because this namespace shadows the module name
/// and would turn `ActionCable.Subscription` into a lookup inside it.
public enum ActionCable {
    public static let version = "2.0.1"
}
