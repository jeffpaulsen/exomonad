{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- | Shoal role config: spawn + notify tools with allow-all hooks.
-- For custom binary agents that connect via rmcp MCP client.
module ShoalRole (config, Tools) where

import ExoMonad
import ExoMonad.Guest.Types (allowResponse, allowStopResponse, postToolUseResponse)
import ExoMonad.Types (HookConfig (..), defaultSessionStartHook)

data Tools mode = Tools
  { spawn :: SpawnTools mode,
    notifyParent :: mode :- NotifyParent
  }
  deriving (Generic)

config :: RoleConfig (Tools AsHandler)
config =
  RoleConfig
    { roleName = "shoal",
      tools =
        Tools
          { spawn = spawnTools,
            notifyParent = mkHandler @NotifyParent
          },
      hooks =
        HookConfig
          { preToolUse = \_ -> pure (allowResponse Nothing),
            postToolUse = \_ -> pure (postToolUseResponse Nothing),
            onStop = \_ -> pure allowStopResponse,
            onSubagentStop = \_ -> pure allowStopResponse,
            onSessionStart = defaultSessionStartHook
          }
    }
