{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
module NixManager.Nix where

import           Data.List                      ( unfoldr
                                                , intercalate
                                                , find
                                                , inits
                                                )
import           System.FilePath                ( (</>) )
import           System.Directory               ( listDirectory )
import           Control.Exception              ( catch
                                                , IOException
                                                )
import           Data.Map.Strict                ( Map
                                                , elems
                                                )
import           Data.ByteString.Lazy           ( ByteString
                                                , hGetContents
                                                )
import           Data.ByteString.Lazy.Lens      ( unpackedChars )
import           System.Process                 ( createProcess
                                                , proc
                                                , std_out
                                                , StdStream(CreatePipe)
                                                )
import           Data.Text                      ( Text
                                                , toLower
                                                , strip
                                                )
import           Data.Aeson                     ( FromJSON
                                                , Value(Object)
                                                , parseJSON
                                                , (.:)
                                                , eitherDecode
                                                )
import           Control.Lens                   ( (^.)
                                                , makeLenses
                                                , view
                                                , to
                                                )
import           Data.Text.Lens                 ( unpacked
                                                , packed
                                                )
import           Control.Monad                  ( mzero
                                                , void
                                                )


data NixPackage = NixPackage {
    _npName :: Text
  , _npVersion :: Text
  , _npDescription :: Text
  , _npInstalled :: Bool
  } deriving(Eq,Show)

makeLenses ''NixPackage

instance FromJSON NixPackage where
  parseJSON (Object v) =
    NixPackage
      <$> v
      .:  "pkgName"
      <*> v
      .:  "version"
      <*> v
      .:  "description"
      <*> pure False
  parseJSON _ = mzero

decodeNixSearchResult :: ByteString -> Either String (Map Text NixPackage)
decodeNixSearchResult = eitherDecode

nixSearch :: Text -> IO (Either String [NixPackage])
nixSearch t = do
  (_, Just hout, _, _) <- createProcess
    (proc "nix" ["search", t ^. unpacked, "--json"]) { std_out = CreatePipe }
  out <- hGetContents hout
  pure (elems <$> decodeNixSearchResult out)

nixSearchUnsafe :: Text -> IO [NixPackage]
nixSearchUnsafe t = do
  result <- nixSearch t
  case result of
    Left  e -> error e
    Right v -> pure v

splitRepeat :: Char -> String -> [String]
splitRepeat c = unfoldr f
 where
  f :: String -> Maybe (String, String)
  f "" = Nothing
  f x  = case span (/= c) x of
    (before, []       ) -> Just (before, "")
    (before, _ : after) -> Just (before, after)

matchName :: String -> [FilePath] -> Maybe FilePath
matchName pkgName bins =
  let undashed :: [String]
      undashed = splitRepeat '-' pkgName
      parts :: [String]
      parts = intercalate "-" <$> reverse (inits undashed)
  in  find (`elem` bins) parts

-- TODO: Error handling
getExecutables :: NixPackage -> IO (FilePath, [FilePath])
getExecutables pkg = do
  (_, Just hout, _, _) <- createProcess
    (proc "nix-build"
          ["-A", pkg ^. npName . unpacked, "--no-out-link", "<nixpkgs>"]
    ) { std_out = CreatePipe
      }
  packagePath <- view (unpackedChars . packed . to strip . unpacked)
    <$> hGetContents hout
  let binPath = packagePath </> "bin"
  bins <- listDirectory binPath `catch` \(_ :: IOException) -> pure []
  let normalizedName = pkg ^. npName . to toLower . unpacked
  case matchName normalizedName bins of
    Nothing      -> pure (binPath, bins)
    Just matched -> pure (binPath, [matched])

startProgram :: FilePath -> IO ()
startProgram fn = void $ createProcess (proc fn [])
