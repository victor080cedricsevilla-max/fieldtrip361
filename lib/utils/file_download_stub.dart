/// Non-web fallback for [downloadTextFile].
///
/// Mobile has no browser download tray, and pulling in a path-provider plus a
/// share sheet for what is an admin-only convenience is not worth the weight.
/// Returning false lets the caller offer the text to copy instead.
bool downloadTextFile(String fileName, String content) => false;
