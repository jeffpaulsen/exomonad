{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | Shoal companion role: shift_focus + render_memory tools.
--
-- The Shoal agent runs as Claude Code in ~/dev/shoal-deploy/.
-- Memory is rendered from jinja templates via the shoal-memory-render CLI.
-- shift_focus writes a handoff note, re-renders memory with new tags,
-- and signals the session should end (the orchestrator forks a new session).
module ShoalRole (config, Tools) where

import Data.Aeson (FromJSON, Value, object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Data.Vector qualified as V
import Effects.Fs qualified as Fs
import Effects.Process qualified as Proc
import Control.Monad.Freer (Eff)
import ExoMonad
import ExoMonad.Effects.Fs (FsWriteFile)
import ExoMonad.Effects.Process (ProcessRun)
import ExoMonad.Guest.Tool.Schema (genericToolSchemaWith)
import ExoMonad.Guest.Tool.SuspendEffect (suspendEffect)
import ExoMonad.Guest.Types (Effects)
import ExoMonad.Guest.Tools.Events
  ( NotifyParentArgs,
    notifyParentCore,
    notifyParentDescription,
    notifyParentSchema,
  )
import ExoMonad.Guest.Types
  ( BeforeModelOutput (..),
    AfterModelOutput (..),
    allowResponse,
    allowStopResponse,
    postToolUseResponse,
  )
import ExoMonad.Types (HookConfig (..), defaultSessionStartHook)

-- ============================================================================
-- Constants
-- ============================================================================

renderBinary :: TL.Text
renderBinary = "shoal-memory-render"

memoryDir :: TL.Text
memoryDir = "/home/inanna/.shoal/memory"

outputDir :: TL.Text
outputDir = "/home/inanna/dev/shoal-deploy/memory"

-- ============================================================================
-- shift_focus tool
-- ============================================================================

data ShiftFocusArgs = ShiftFocusArgs
  { sfTags :: [Text],
    sfHandoff :: Text
  }
  deriving (Generic, Show)

instance FromJSON ShiftFocusArgs

data ShiftFocus

instance MCPTool ShiftFocus where
  type ToolArgs ShiftFocus = ShiftFocusArgs
  toolName = "shift_focus"
  toolDescription =
    "Shift conversation focus to new tags. Writes a handoff note for the next session, \
    \re-renders memory blocks with the new tags, and signals session end. \
    \The orchestrator will fork a new session from the seed with updated memory. \
    \Use this when the conversation topic changes significantly \
    \(e.g., from coding to personal reflection, or from general chat to a specific project)."
  toolSchema =
    genericToolSchemaWith @ShiftFocusArgs
      [ ("tags", "New active tags (e.g. [\"coding\", \"coding:rust\"])"),
        ("handoff", "Message to pass to the next session explaining context and what was happening")
      ]
  toolHandlerEff args = do
    -- 1. Write handoff note
    let handoffPath = TL.toStrict outputDir <> "/_handoff.md"
    handoffResult <-
      suspendEffect @FsWriteFile
        ( Fs.WriteFileRequest
            { Fs.writeFileRequestPath = TL.fromStrict handoffPath,
              Fs.writeFileRequestContent = TL.fromStrict (sfHandoff args),
              Fs.writeFileRequestCreateParents = True,
              Fs.writeFileRequestAppend = False
            }
        )
    case handoffResult of
      Left err -> pure $ errorResult ("Failed to write handoff: " <> T.pack (show err))
      Right _ -> do
        -- 2. Re-render memory with new tags
        let tagsArg = T.intercalate "," (sfTags args)
        renderResult <-
          suspendEffect @ProcessRun
            ( Proc.RunRequest
                { Proc.runRequestCommand = renderBinary,
                  Proc.runRequestArgs =
                    V.fromList
                      [ "--memory-dir",
                        memoryDir,
                        "--output-dir",
                        outputDir,
                        "--tags",
                        TL.fromStrict tagsArg,
                        "--context",
                        "companion"
                      ],
                  Proc.runRequestWorkingDir = "/home/inanna/dev/shoal-deploy",
                  Proc.runRequestEnv = Map.empty,
                  Proc.runRequestTimeoutMs = 30000
                }
            )
        case renderResult of
          Left err ->
            pure $ errorResult ("Failed to render memory: " <> T.pack (show err))
          Right resp
            | Proc.runResponseExitCode resp /= 0 ->
                pure $
                  errorResult $
                    "shoal-memory-render failed (exit "
                      <> T.pack (show (Proc.runResponseExitCode resp))
                      <> "): "
                      <> TL.toStrict (Proc.runResponseStderr resp)
            | otherwise ->
                pure $
                  successResult $
                    object
                      [ "success" .= True,
                        "new_tags" .= sfTags args,
                        "rendered" .= TL.toStrict (Proc.runResponseStderr resp),
                        "action" .= ("session_end_requested" :: Text),
                        "message"
                          .= ( "Memory re-rendered with new tags. This session should now end. "
                                 <> "The orchestrator will fork a new session with updated context."
                                 :: Text
                             )
                      ]

-- ============================================================================
-- render_memory tool
-- ============================================================================

data RenderMemoryArgs = RenderMemoryArgs
  { rmTags :: [Text],
    rmContext :: Maybe Text
  }
  deriving (Generic, Show)

instance FromJSON RenderMemoryArgs

data RenderMemory

instance MCPTool RenderMemory where
  type ToolArgs RenderMemory = RenderMemoryArgs
  toolName = "render_memory"
  toolDescription =
    "Re-render memory blocks with specified tags without ending the session. \
    \Useful for previewing what memory blocks would be active with different tags."
  toolSchema =
    genericToolSchemaWith @RenderMemoryArgs
      [ ("tags", "Tags to render with (e.g. [\"coding\", \"crisis\"])"),
        ("context", "Deployment context: companion or default (default: companion)")
      ]
  toolHandlerEff args = do
    let tagsArg = T.intercalate "," (rmTags args)
        ctx = maybe "companion" id (rmContext args)
    result <-
      suspendEffect @ProcessRun
        ( Proc.RunRequest
            { Proc.runRequestCommand = renderBinary,
              Proc.runRequestArgs =
                V.fromList
                  [ "--memory-dir",
                    memoryDir,
                    "--output-dir",
                    outputDir,
                    "--tags",
                    TL.fromStrict tagsArg,
                    "--context",
                    TL.fromStrict ctx
                  ],
              Proc.runRequestWorkingDir = "/home/inanna/dev/shoal-deploy",
              Proc.runRequestEnv = Map.empty,
              Proc.runRequestTimeoutMs = 30000
            }
        )
    case result of
      Left err -> pure $ errorResult ("render failed: " <> T.pack (show err))
      Right resp
        | Proc.runResponseExitCode resp /= 0 ->
            pure $
              errorResult $
                "shoal-memory-render failed (exit "
                  <> T.pack (show (Proc.runResponseExitCode resp))
                  <> "): "
                  <> TL.toStrict (Proc.runResponseStderr resp)
        | otherwise ->
            pure $
              successResult $
                object
                  [ "success" .= True,
                    "tags" .= rmTags args,
                    "output" .= TL.toStrict (Proc.runResponseStderr resp)
                  ]

-- ============================================================================
-- notify_parent (for communicating with orchestrator)
-- ============================================================================

data ShoalNotifyParent

instance MCPTool ShoalNotifyParent where
  type ToolArgs ShoalNotifyParent = NotifyParentArgs
  toolName = "notify_parent"
  toolDescription = notifyParentDescription
  toolSchema = notifyParentSchema
  toolHandlerEff args = do
    result <- notifyParentCore args
    case result of
      Left err -> pure $ errorResult err
      Right _ -> pure $ successResult $ object ["success" .= True]

-- ============================================================================
-- Tools record + config
-- ============================================================================

data Tools mode = Tools
  { shiftFocus :: mode :- ShiftFocus,
    renderMemory :: mode :- RenderMemory,
    notifyParent :: mode :- ShoalNotifyParent,
    sendMessage :: mode :- SendMessage
  }
  deriving (Generic)

config :: RoleConfig (Tools AsHandler)
config =
  RoleConfig
    { roleName = "shoal",
      tools =
        Tools
          { shiftFocus = mkHandler @ShiftFocus,
            renderMemory = mkHandler @RenderMemory,
            notifyParent = mkHandler @ShoalNotifyParent,
            sendMessage = mkHandler @SendMessage
          },
      hooks =
        HookConfig
          { preToolUse = \_ -> pure (allowResponse Nothing),
            postToolUse = \_ -> pure (postToolUseResponse Nothing),
            onStop = \_ -> pure allowStopResponse,
            onSubagentStop = \_ -> pure allowStopResponse,
            onSessionStart = defaultSessionStartHook,
            beforeModel = \_ -> pure (BeforeModelAllow Nothing),
            afterModel = \_ -> pure (AfterModelAllow Nothing)
          },
      eventHandlers = defaultEventHandlers
    }
