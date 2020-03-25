{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
module NixManager.UpdateHandler
  ( update'
  )
where

import           Data.Text.Encoding             ( decodeUtf8 )
import           System.Exit                    ( ExitCode
                                                  ( ExitSuccess
                                                  , ExitFailure
                                                  )
                                                )
import           NixManager.Process             ( updateProcess
                                                , poResult
                                                , poStdout
                                                , terminate
                                                )
import           NixManager.AdminState          ( AdminState
                                                , asBuildState
                                                , asProcessOutput
                                                , asActiveBuildType
                                                , absCounter
                                                , absProcessData
                                                , AdminBuildState
                                                  ( AdminBuildState
                                                  )
                                                )

import           NixManager.ServiceStateData    ( ssdServiceExpression
                                                , ssdSelectedServiceIdx
                                                )
import           NixManager.ServiceState        ( ServiceState
                                                  ( ServiceStateDownloading
                                                  , ServiceStateInvalidOptions
                                                  )
                                                , _ServiceStateDone
                                                , _ServiceStateDownloading
                                                , ssddCounter
                                                , initServiceState
                                                , ssddVar
                                                , ServiceStateDownloadingData
                                                  ( ServiceStateDownloadingData
                                                  )
                                                )
import qualified NixManager.ServiceDownload    as ServiceDownload
import           System.FilePath                ( (</>) )
import           Data.Text.IO                   ( putStrLn )
import           Data.Foldable                  ( for_ )
import           Data.Monoid                    ( getFirst )
import           Control.Lens                   ( (^.)
                                                , folded
                                                , traversed
                                                , (<>~)
                                                , over
                                                , (&)
                                                , (^?)
                                                , (?~)
                                                , to
                                                , (.~)
                                                , (+~)
                                                , (^?!)
                                                )
import           NixManager.AdminEvent          ( AdminEvent
                                                  ( AdminEventRebuild
                                                  , AdminEventRebuildStarted
                                                  , AdminEventRebuildWatch
                                                  , AdminEventRebuildCancel
                                                  , AdminEventRebuildFinished
                                                  , AdminEventBuildTypeChanged
                                                  , AdminEventAskPassWatch
                                                  )
                                                )
import           NixManager.ManagerState        ( ManagerState(..)
                                                , msInstallingPackage
                                                , msSelectedPackage
                                                , msAdminState
                                                , msServiceState
                                                , msLatestMessage
                                                , msPackageCache
                                                , msSelectedPackageIdx
                                                , msSearchString
                                                )
import           NixManager.NixService          ( writeServiceFile )
import           NixManager.ServicesEvent       ( ServicesEvent
                                                  ( ServicesEventDownloadStart
                                                  , ServicesEventSettingChanged
                                                  , ServicesEventDownloadCancel
                                                  , ServicesEventStateResult
                                                  , ServicesEventStateReload
                                                  , ServicesEventDownloadCheck
                                                  , ServicesEventDownloadStarted
                                                  , ServicesEventSelected
                                                  )
                                                )
import           NixManager.Util                ( MaybeError(Success, Error)
                                                , showText
                                                , threadDelayMillis
                                                )
import           NixManager.Message             ( errorMessage
                                                , infoMessage
                                                )
import           NixManager.ManagerEvent        ( ManagerEvent(..) )
import           NixManager.Rebuild             ( askPass
                                                , rebuild
                                                )
import           NixManager.PackageSearch       ( installPackage
                                                , readCache
                                                , startProgram
                                                , uninstallPackage
                                                , getExecutables
                                                )
import           NixManager.NixPackage          ( NixPackage
                                                , npName
                                                )
import           GI.Gtk.Declarative.App.Simple  ( Transition(Transition, Exit) )
import           Prelude                 hiding ( length
                                                , putStrLn
                                                )
tryInstall :: NixPackage -> IO (Maybe ManagerEvent)
tryInstall p = do
  bins <- getExecutables p
  case bins of
    (_, []) -> pure
      (Just
        (ManagerEventShowMessage
          (errorMessage "No binaries found in this package!")
        )
      )
    (bp, [singleBinary]) -> do
      startProgram (bp </> singleBinary)
      pure Nothing
    multipleBinaries -> do
      putStrLn $ "found more bins: " <> showText multipleBinaries
      pure
        (Just
          (ManagerEventShowMessage
            (errorMessage "Multiple binaries found in this package!")
          )
        )

pureTransition :: ManagerState -> Transition ManagerState ManagerEvent
pureTransition x = Transition x (pure Nothing)

adminEvent :: AdminEvent -> Maybe ManagerEvent
adminEvent = Just . ManagerEventAdmin

servicesEvent :: ServicesEvent -> Maybe ManagerEvent
servicesEvent = Just . ManagerEventServices

updateServicesEvent
  :: ManagerState -> ServicesEvent -> Transition ManagerState ManagerEvent
updateServicesEvent s ServicesEventDownloadStart = Transition
  s
  (servicesEvent . ServicesEventDownloadStarted <$> ServiceDownload.start)
updateServicesEvent s (ServicesEventSettingChanged setter) =
  let newState = over
        (msServiceState . _ServiceStateDone . ssdServiceExpression)
        setter
        s
  in  Transition newState $ do
        writeServiceFile
          (   newState
          ^?! msServiceState
          .   _ServiceStateDone
          .   ssdServiceExpression
          )
        pure Nothing
updateServicesEvent s ServicesEventDownloadCancel = Transition s $ do
  for_ (s ^? msServiceState . _ServiceStateDownloading . ssddVar)
       ServiceDownload.cancel
  pure (servicesEvent ServicesEventStateReload)
updateServicesEvent s (ServicesEventStateResult newServiceState) =
  pureTransition (s & msServiceState .~ newServiceState)
updateServicesEvent s ServicesEventStateReload =
  Transition s (servicesEvent . ServicesEventStateResult <$> initServiceState)
updateServicesEvent s (ServicesEventDownloadCheck var) =
  Transition (s & msServiceState . _ServiceStateDownloading . ssddCounter +~ 1)
    $ do
        downloadResult <- ServiceDownload.result var
        case downloadResult of
          Just (Error e) -> pure
            (servicesEvent
              (ServicesEventStateResult (ServiceStateInvalidOptions (Just e)))
            )
          Just (Success _) -> pure (servicesEvent ServicesEventStateReload)
          Nothing          -> threadDelayMillis 500
            >> pure (servicesEvent (ServicesEventDownloadCheck var))
updateServicesEvent s (ServicesEventDownloadStarted var) =
  Transition
      (s & msServiceState .~ ServiceStateDownloading
        (ServiceStateDownloadingData 0 var)
      )
    $ do
        threadDelayMillis 500
        pure (servicesEvent (ServicesEventDownloadCheck var))
updateServicesEvent s (ServicesEventSelected i) = pureTransition
  (s & msServiceState . _ServiceStateDone . ssdSelectedServiceIdx .~ i)


updateAdminEvent
  :: ManagerState
  -> AdminState
  -> AdminEvent
  -> Transition ManagerState ManagerEvent
updateAdminEvent ms _ AdminEventRebuild =
  Transition ms (adminEvent . AdminEventAskPassWatch mempty <$> askPass)
updateAdminEvent ms _ AdminEventRebuildCancel =
  Transition (ms & msAdminState . asBuildState .~ Nothing) $ do
    terminate (ms ^?! msAdminState . asBuildState . folded . absProcessData)
    pure Nothing
updateAdminEvent ms _ (AdminEventAskPassWatch po pd) = Transition ms $ do
  newpo <- updateProcess pd
  let totalPo = po <> newpo
  case totalPo ^. poResult . to getFirst of
    Nothing -> do
      threadDelayMillis 500
      pure (adminEvent (AdminEventAskPassWatch totalPo pd))
    Just ExitSuccess -> do
      rebuildPo <- rebuild (totalPo ^. poStdout . to decodeUtf8)
      pure (adminEvent (AdminEventRebuildStarted rebuildPo))
    Just (ExitFailure _) -> pure Nothing
updateAdminEvent ms _ (AdminEventRebuildStarted pd) =
  Transition
      (  ms
      &  msAdminState
      .  asBuildState
      ?~ AdminBuildState 0 pd
      &  msAdminState
      .  asProcessOutput
      .~ mempty
      )
    $ pure (adminEvent (AdminEventRebuildWatch mempty pd))
updateAdminEvent ms _ (AdminEventRebuildWatch priorOutput pd) =
  Transition
      (  ms
      &  msAdminState
      .  asProcessOutput
      .~ priorOutput
      &  msAdminState
      .  asBuildState
      .  traversed
      .  absCounter
      +~ 1
      )
    $ do
        updates <- updateProcess pd
        let newOutput = priorOutput <> updates
        case updates ^. poResult . to getFirst of
          Nothing -> do
            threadDelayMillis 500
            pure (adminEvent (AdminEventRebuildWatch newOutput pd))
          Just _ -> pure (adminEvent (AdminEventRebuildFinished newOutput))
updateAdminEvent ms _ (AdminEventRebuildFinished totalOutput) = pureTransition
  (  ms
  &  msAdminState
  .  asBuildState
  .~ Nothing
  &  msAdminState
  .  asProcessOutput
  .~ (totalOutput & poStdout <>~ "\n\nFinished!")
  )
updateAdminEvent ms _ (AdminEventBuildTypeChanged newType) =
  pureTransition (ms & msAdminState . asActiveBuildType .~ newType)





update' :: ManagerState -> ManagerEvent -> Transition ManagerState ManagerEvent
update' s (ManagerEventAdmin    ae) = updateAdminEvent s (s ^. msAdminState) ae
update' s (ManagerEventServices se) = updateServicesEvent s se
update' _ ManagerEventClosed        = Exit
update' s (ManagerEventShowMessage e) =
  pureTransition (s & msLatestMessage ?~ e)
update' s (ManagerEventInstallCompleted cache) = Transition
  (s & msPackageCache .~ cache)
  (pure (Just (ManagerEventShowMessage (infoMessage "Install completed!"))))
update' s (ManagerEventUninstallCompleted cache) = Transition
  (s & msPackageCache .~ cache)
  (pure (Just (ManagerEventShowMessage (infoMessage "Uninstall completed!"))))
update' s ManagerEventInstall = case s ^. msSelectedPackage of
  Nothing       -> pureTransition s
  Just selected -> Transition s $ do
    installResult <- installPackage (selected ^. npName)
    cacheResult   <- readCache
    case installResult >>= const cacheResult of
      Success newCache -> pure (Just (ManagerEventInstallCompleted newCache))
      Error e ->
        pure
          (Just
            (ManagerEventShowMessage (errorMessage ("Install failed: " <> e)))
          )
update' s ManagerEventUninstall = case s ^. msSelectedPackage of
  Nothing       -> pureTransition s
  Just selected -> Transition s $ do
    uninstallResult <- uninstallPackage (selected ^. npName)
    cacheResult     <- readCache
    case uninstallResult >>= const cacheResult of
      Success newCache -> pure (Just (ManagerEventUninstallCompleted newCache))
      Error e ->
        pure
          (Just
            (ManagerEventShowMessage (errorMessage ("Uninstall failed: " <> e)))
          )
update' s ManagerEventTryInstall = case s ^. msSelectedPackage of
  Nothing -> pureTransition s
  Just selected ->
    Transition (s & msInstallingPackage ?~ selected) (tryInstall selected)
update' s (ManagerEventPackageSelected i) =
  pureTransition (s & msSelectedPackageIdx .~ i)
update' s (ManagerEventSearchChanged t) =
  pureTransition (s & msSearchString .~ t)
update' s ManagerEventDiscard = pureTransition s

