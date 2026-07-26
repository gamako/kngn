//! Initial grid patterns for DrumMachine / BassMachine. Single source for both apps.

pub const KICK_ON: u16 = 0x1111; // steps 0,4,8,12 (four-on-floor)
pub const HAT_ON: u16 = 0x4444; // steps 2,6,10,14 (off-beat eighths)
pub const CLAP_ON: u16 = 0x1010; // steps 4,12 (toward beats 2 and 4)
pub const BASS_ON: u16 = 0x4949; // step 0,3,6,8,11,14
pub const BASS_ACCENT: u16 = 0x0101; // step 0,8
pub const BASS_SLIDE: u16 = 0x0808; // step 3,11
pub const BASS_DEG = [16]i8{ 0, 0, 0, 3, 0, 0, 2, 0, 0, 0, 0, 5, 0, 0, 2, 0 };
