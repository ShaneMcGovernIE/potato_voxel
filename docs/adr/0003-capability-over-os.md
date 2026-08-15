# Capability verdicts replace OS-name checks

The sandbox removed `love.system.getOS()`, so nothing can ask which
device it is on. Where a platform gate survived (shadows), it was
replaced by a runtime capability verdict the code already computes; where
a feature's whole point was platform-gated (FOREST FX), the feature was
removed instead (see ADR 0004). The old blanket "no shadows on iOS" ban
is deleted: the 1.5.0 session-log gates already say exactly why shadows
cannot run, and the player has a SHADOWS OFF row of their own.
