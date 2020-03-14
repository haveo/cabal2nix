{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric #-}

module Distribution.Nixpkgs.Fetch
  ( Source(..)
  , Hash(..)
  , DerivationSource(..), fromDerivationSource, urlDerivationSource
  , fetch
  , fetchWith
  ) where

import Control.Applicative
import Control.DeepSeq
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Maybe
import Data.Aeson
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.List as L
import Data.Maybe
import GHC.Generics ( Generic )
import Language.Nix.PrettyPrinting as PP
import System.Directory
import System.Environment
import System.Exit
import System.IO
import System.Process

-- | A source is a location from which we can fetch, such as a HTTP URL, a GIT URL, ....
data Source = Source
  { sourceUrl       :: String       -- ^ URL to fetch from.
  , sourceRevision  :: String       -- ^ Revision to use. For protocols where this doesn't make sense (such as HTTP), this
                                    --   should be the empty string.
  , sourceHash      :: Hash         -- ^ The expected hash of the source, if available.
  , sourceCabalDir  :: String       -- ^ Directory where Cabal file is found.
  } deriving (Show, Eq, Ord, Generic)

instance NFData Source

data Hash = Certain String | Guess String | UnknownHash
  deriving (Show, Eq, Ord, Generic)

instance NFData Hash

isUnknown :: Hash -> Bool
isUnknown UnknownHash = True
isUnknown _           = False

hashToList :: Hash -> [String]
hashToList (Certain s) = [s]
hashToList _           = []

-- | A source for a derivation. It always needs a hash and also has a protocol attached to it (url, git, svn, ...).
-- A @DerivationSource@ also always has it's revision fully resolved (not relative revisions like @master@, @HEAD@, etc).
data DerivationSource = DerivationSource
  { derivKind     :: String -- ^ The kind of the source. The name of the build-support fetch derivation should be fetch<kind>.
  , derivUrl      :: String -- ^ URL to fetch from.
  , derivRevision :: String -- ^ Revision to use. Leave empty if the fetcher doesn't support revisions.
  , derivHash     :: String -- ^ The hash of the source.
  , derivSubmodule :: Maybe Bool -- ^ The fetchSubmodule setting (if any)
  }
  deriving (Show, Eq, Ord, Generic)

instance NFData DerivationSource

instance FromJSON DerivationSource where
  parseJSON (Object o) = DerivationSource (error "undefined DerivationSource.kind")
        <$> o .: "url"
        <*> o .: "rev"
        <*> o .: "sha256"
        <*> o .: "fetchSubmodules"
  parseJSON _ = error "invalid DerivationSource"

instance PP.Pretty DerivationSource where
  pPrint DerivationSource {..} =
    let isHackagePackage = "mirror://hackage/" `L.isPrefixOf` derivUrl
        fetched = derivKind /= ""
    in if isHackagePackage then attr "sha256" $ string derivHash
       else if not fetched then attr "src" $ text derivUrl
            else vcat
                 [ text "src" <+> equals <+> text ("fetch" ++ derivKind) <+> lbrace
                 , nest 2 $ vcat
                   [ attr "url" $ text derivUrl
                   , attr "sha256" $ string derivHash
                   , if derivRevision /= "" then attr "rev" (string derivRevision) else PP.empty
                   , boolattr "fetchSubmodules" (isJust derivSubmodule) (fromJust derivSubmodule)
                   ]
                 , rbrace PP.<> semi
                 ]


urlDerivationSource :: String -> String -> DerivationSource
urlDerivationSource url hash = DerivationSource "url" url "" hash Nothing

fromDerivationSource :: DerivationSource -> Source
fromDerivationSource DerivationSource{..} = Source derivUrl derivRevision (Certain derivHash) "."

-- | Fetch a source, trying any of the various nix-prefetch-* scripts.
fetch :: forall a.
         Bool                                   -- ^ If True, fetch submodules when the source is a git repository
      -> (String -> MaybeT IO a)                -- ^ This function is passed the output path name as an argument.
                                                -- It should return 'Nothing' if the file doesn't match the expected format.
                                                -- This is required, because we cannot always check if a download succeeded otherwise.
      -> Source                                 -- ^ The source to fetch from.
      -> IO (Maybe (DerivationSource, a))       -- ^ The derivation source and the result of the processing function. Returns Nothing if the download failed.
fetch optSubModules f = runMaybeT . fetchers where
  fetchers :: Source -> MaybeT IO (DerivationSource, a)
  fetchers source = msum . (fetchLocal source :) $ map (\fetcher -> fetchWith fetcher source >>= process)
    [ (False, "url", [])
    , (True, "git", ["--fetch-submodules" | optSubModules ])
    , (True, "hg", [])
    , (True, "svn", [])
    , (True, "bzr", [])
    ]

  -- | Remove '/' from the end of the path. Nix doesn't accept paths that
  -- end in a slash.
  stripSlashSuffix :: String -> String
  stripSlashSuffix = reverse . dropWhile (== '/') . reverse

  fetchLocal :: Source -> MaybeT IO (DerivationSource, a)
  fetchLocal src = do
    let path = stripSlashSuffix $ stripPrefix "file://" $ sourceUrl src
    existsFile <- liftIO $ doesFileExist path
    existsDir  <- liftIO $ doesDirectoryExist path
    guard $ existsDir || existsFile
    let path' | '/' `elem` path = path
              | otherwise       = "./" ++ path
    process (localDerivationSource path', path') <|> localArchive path'

  localArchive :: FilePath -> MaybeT IO (DerivationSource, a)
  localArchive path = do
    absolutePath <- liftIO $ canonicalizePath path
    unpacked <- snd <$> fetchWith (False, "url", ["--unpack"]) (Source ("file://" ++ absolutePath) "" UnknownHash ".")
    process (localDerivationSource absolutePath, unpacked)

  process :: (DerivationSource, FilePath) -> MaybeT IO (DerivationSource, a)
  process (derivSource, file) = (,) derivSource <$> f file

  localDerivationSource p = DerivationSource "" p "" "" Nothing

-- | Like 'fetch', but allows to specify which script to use.
fetchWith :: (Bool, String, [String]) -> Source -> MaybeT IO (DerivationSource, FilePath)
fetchWith (supportsRev, kind, addArgs) source = do
  unless ((sourceRevision source /= "") || isUnknown (sourceHash source) || not supportsRev) $
    liftIO (hPutStrLn stderr "** need a revision for VCS when the hash is given. skipping.") >> mzero

  MaybeT $ liftIO $ do
    envs <- getEnvironment
    (Nothing, Just stdoutH, _, processH) <- createProcess (proc script args)
      { env = Just $ ("PRINT_PATH", "1") : envs
      , std_in = Inherit
      , std_err = Inherit
      , std_out = CreatePipe
      }

    exitCode <- waitForProcess processH
    case exitCode of
      ExitFailure _ -> return Nothing
      ExitSuccess   -> do
        buf <- BS.hGetContents stdoutH
        let (l,ls) = case reverse (BS.lines buf) of
                       []     -> error "This can't happen, but GHC doesn't know that."
                       (x:xs) -> (x,xs)
            buf'   = BS.unlines (reverse ls)
        case length ls of
          0 -> return Nothing
          1 -> return (Just (DerivationSource { derivKind = kind
                                              , derivUrl = sourceUrl source
                                              , derivRevision = ""
                                              , derivHash = BS.unpack (head ls)
                                              , derivSubmodule = Nothing
                                              }
                            , sourceUrl source))
          _ -> case eitherDecode buf' of
                 Left err -> error ("invalid JSON: " ++ err ++ " in " ++ show buf')
                 Right ds -> return (Just (ds { derivKind = kind }, BS.unpack l))
 where

   script :: String
   script = "nix-prefetch-" ++ kind

   args :: [String]
   args = addArgs ++ sourceUrl source : [ sourceRevision source | supportsRev ] ++ hashToList (sourceHash source)

stripPrefix :: Eq a => [a] -> [a] -> [a]
stripPrefix prefix as
  | prefix' == prefix = stripped
  | otherwise = as
 where
  (prefix', stripped) = splitAt (length prefix) as
