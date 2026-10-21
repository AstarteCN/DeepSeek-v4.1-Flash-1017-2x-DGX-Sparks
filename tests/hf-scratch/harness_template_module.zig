//! Offline harness adapter only: expose the actual internal Value size, while
//! forwarding every HfText template call unchanged to the pinned implementation.
const impl = @import("template.zig");
pub const Value = @import("value.zig").Value;
pub const Error = impl.Error;
pub const Diag = impl.Diag;
pub const Compiled = impl.Compiled;
pub const compile = impl.compile;
pub const render = impl.render;
pub const renderChat = impl.renderChat;
