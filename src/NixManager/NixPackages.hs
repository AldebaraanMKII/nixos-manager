{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE ScopedTypeVariables #-}
module NixManager.NixPackages
  ( searchPackages
  , locateLocalPackagesFile
  , locateRootPackagesFile
  , locateLocalPackagesFileMaybeCreate
  , installPackage
  , readInstalledPackages
  , readPendingPackages
  , readPendingUninstallPackages
  , readPackageCache
  , startProgram
  , uninstallPackage
  , executablesFromStorePath
  , dryInstall
  )
where

import           NixManager.Constants           ( appName
                                                , rootManagerPath
                                                )
import           Data.ByteString                ( ByteString )
import           System.Exit                    ( ExitCode
                                                  ( ExitSuccess
                                                  , ExitFailure
                                                  )
                                                )
import           NixManager.BashDsl             ( Expr(Command)
                                                , Arg(LiteralArg)
                                                , nixSearch
                                                )
import           Data.Map.Strict                ( singleton )
import           Control.Monad                  ( void
                                                , unless
                                                )
import           System.Directory               ( listDirectory
                                                , getXdgDirectory
                                                , doesFileExist
                                                , XdgDirectory(XdgConfig)
                                                )
import           System.FilePath                ( (</>)
                                                , takeFileName
                                                )
import           Data.List                      ( intercalate
                                                , (\\)
                                                , find
                                                , inits
                                                )
import           Data.Text                      ( Text
                                                , pack
                                                , toLower
                                                , strip
                                                , stripPrefix
                                                )
import           NixManager.Util                ( MaybeError(Success, Error)
                                                , decodeUtf8
                                                , fromStrictBS
                                                , splitRepeat
                                                , addToError
                                                , ifSuccessIO
                                                , showText
                                                )
import qualified Data.Text                     as Text
import           Data.String                    ( IsString )
import           NixManager.NixExpr             ( NixExpr
                                                  ( NixSymbol
                                                  , NixSet
                                                  , NixList
                                                  , NixFunctionDecl
                                                  )
                                                , NixFunction(NixFunction)
                                                , _NixFunctionDecl
                                                , nfExpr
                                                , _NixSymbol
                                                , evalSymbols
                                                , _NixSet
                                                , parseNixFile
                                                , writeNixFile
                                                , _NixList
                                                )
import           Control.Exception              ( catch
                                                , IOException
                                                )
import           NixManager.NixPackageStatus    ( NixPackageStatus
                                                  ( NixPackageNothing
                                                  , NixPackageInstalled
                                                  , NixPackagePendingInstall
                                                  , NixPackagePendingUninstall
                                                  )
                                                )
import           NixManager.NixPackage          ( NixPackage
                                                , npPath
                                                , npName
                                                , npStatus
                                                , readPackagesJson
                                                )
import           Control.Lens                   ( (^.)
                                                , (.~)
                                                , (^?)
                                                , (^?!)
                                                , ix
                                                , Traversal'
                                                , hasn't
                                                , folded
                                                , only
                                                , (<>~)
                                                , (&)
                                                , to
                                                , (%~)
                                                )
import           Data.Text.Lens                 ( unpacked )
import           NixManager.Process             ( runProcess
                                                , ProcessData
                                                , waitUntilFinished
                                                , poStdout
                                                , poStderr
                                                , poResult
                                                )
import           Data.Monoid                    ( First(getFirst) )

searchPackages :: Text -> IO (MaybeError [NixPackage])
searchPackages t = do
  pd <- runProcess Nothing (nixSearch t)
  po <- waitUntilFinished pd
  let
    processedResult = addToError
      "Error parsing output of \"nix search\" command. This could be due to changes in this command in a later version (and doesn't fix itself). Please open an issue in the nixos-manager repository. The error was: "
      (readPackagesJson (po ^. poStdout . fromStrictBS))
  case po ^?! poResult . to getFirst . folded of
    ExitSuccess      -> pure processedResult
    ExitFailure 1    -> pure processedResult
    ExitFailure code -> pure
      (Error
        (  "Error executing \"nix search\" command (exit code "
        <> showText code
        <> "): standard error output: "
        <> (po ^. poStderr . decodeUtf8)
        )
      )


matchName :: String -> [FilePath] -> Maybe FilePath
matchName pkgName bins =
  let undashed :: [String]
      undashed = splitRepeat '-' pkgName
      parts :: [String]
      parts = intercalate "-" <$> reverse (inits undashed)
  in  find (`elem` bins) parts

dryInstall :: NixPackage -> IO ProcessData
dryInstall pkg =
  let realPath = pkg ^?! npPath . to (stripPrefix "nixpkgs.") . folded
  in  runProcess
        Nothing
        (Command "nix-build"
                 ["-A", LiteralArg realPath, "--no-out-link", "<nixpkgs>"]
        )

executablesFromStorePath
  :: NixPackage -> ByteString -> IO (FilePath, [FilePath])
executablesFromStorePath pkg stdout = do
  let packagePath = stdout ^. decodeUtf8 . to strip . unpacked
  let binPath     = packagePath </> "bin"
  bins <- listDirectory binPath `catch` \(_ :: IOException) -> pure []
  let normalizedName = pkg ^. npName . to toLower . unpacked
  case matchName normalizedName bins of
    Nothing      -> pure (binPath, bins)
    Just matched -> pure (binPath, [matched])

startProgram :: FilePath -> IO ()
startProgram fn = void (runProcess Nothing (Command (pack fn) []))

packageLens :: Traversal' NixExpr NixExpr
packageLens =
  _NixFunctionDecl . nfExpr . _NixSet . ix "environment.systemPackages"

emptyPackagesFile :: NixExpr
emptyPackagesFile = NixFunctionDecl
  (NixFunction
    ["config", "pkgs", "..."]
    (NixSet (singleton "environment.systemPackages" (NixList mempty)))
  )

packagesFileName :: IsString s => s
packagesFileName = "packages.nix"

locateLocalPackagesFile :: IO FilePath
locateLocalPackagesFile =
  getXdgDirectory XdgConfig (appName </> packagesFileName)

locateRootPackagesFile :: IO FilePath
locateRootPackagesFile = do
  localFile <- locateLocalPackagesFile
  pure (rootManagerPath </> takeFileName localFile)

locateLocalPackagesFileMaybeCreate :: IO FilePath
locateLocalPackagesFileMaybeCreate = do
  pkgsFile <- locateLocalPackagesFile
  exists   <- doesFileExist pkgsFile
  unless exists (writeLocalPackages emptyPackagesFile)
  pure pkgsFile

parsePackagesExpr :: FilePath -> IO (MaybeError NixExpr)
parsePackagesExpr fp =
  addToError
      ("Error parsing the "
      <> showText fp
      <> " file. This is most likely a syntax error, please investigate the file itself and fix the error. Then restart nixos-manager. The error was: "
      )
    <$> parseNixFile fp emptyPackagesFile

parsePackages :: FilePath -> IO (MaybeError [Text])
parsePackages fp = ifSuccessIO (parsePackagesExpr fp) $ \expr ->
  case expr ^? packageLens of
    Just packages -> pure (Success (Text.drop 5 <$> evalSymbols packages))
    Nothing -> pure (Error "Couldn't find packages node in packages.nix file.")

parseLocalPackages :: IO (MaybeError [Text])
parseLocalPackages = locateLocalPackagesFile >>= parsePackages

parseLocalPackagesExpr :: IO (MaybeError NixExpr)
parseLocalPackagesExpr = locateLocalPackagesFile >>= parsePackagesExpr

writeLocalPackages :: NixExpr -> IO ()
writeLocalPackages e = do
  pkgsFile <- locateLocalPackagesFile
  writeNixFile pkgsFile e

packagesOrEmpty :: IO FilePath -> IO (MaybeError [Text])
packagesOrEmpty fp' = do
  fp       <- fp'
  fpExists <- doesFileExist fp
  if fpExists then parsePackages fp else pure (Success [])

readInstalledPackages :: IO (MaybeError [Text])
readInstalledPackages = packagesOrEmpty locateRootPackagesFile

readPendingPackages :: IO (MaybeError [Text])
readPendingPackages =
  ifSuccessIO (packagesOrEmpty locateLocalPackagesFile) $ \local ->
    ifSuccessIO (packagesOrEmpty locateRootPackagesFile)
      $ \root -> pure (Success (local \\ root))

readPendingUninstallPackages :: IO (MaybeError [Text])
readPendingUninstallPackages =
  ifSuccessIO (packagesOrEmpty locateLocalPackagesFile) $ \local ->
    ifSuccessIO (packagesOrEmpty locateRootPackagesFile)
      $ \root -> pure (Success (root \\ local))

packagePrefix :: Text
packagePrefix = "pkgs."

installPackage :: Text -> IO (MaybeError ())
installPackage p = ifSuccessIO parseLocalPackagesExpr $ \expr -> do
  writeLocalPackages
    (expr & packageLens . _NixList <>~ [NixSymbol (packagePrefix <> p)])
  pure (Success ())

uninstallPackage :: Text -> IO (MaybeError ())
uninstallPackage p = ifSuccessIO parseLocalPackagesExpr $ \expr -> do
  writeLocalPackages
    (expr & packageLens . _NixList %~ filter
      (hasn't (_NixSymbol . only (packagePrefix <> p)))
    )
  pure (Success ())

evaluateStatus name installedPackages pendingPackages pendingUninstallPackages
  | name `elem` pendingUninstallPackages = NixPackagePendingUninstall
  | name `elem` pendingPackages          = NixPackagePendingInstall
  | name `elem` installedPackages        = NixPackageInstalled
  | otherwise                            = NixPackageNothing

readPackageCache :: IO (MaybeError [NixPackage])
readPackageCache = ifSuccessIO (searchPackages "") $ \cache ->
  ifSuccessIO readInstalledPackages $ \installedPackages ->
    ifSuccessIO readPendingPackages $ \pendingPackages ->
      ifSuccessIO readPendingUninstallPackages $ \pendingUninstallPackages ->
        pure
          $   Success
          $   (\ip ->
                ip
                  &  npStatus
                  .~ evaluateStatus (ip ^. npName)
                                    installedPackages
                                    pendingPackages
                                    pendingUninstallPackages
              )
          <$> cache

