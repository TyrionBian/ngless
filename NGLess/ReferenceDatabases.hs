{-# LANGUAGE OverloadedStrings #-}

module ReferenceDatabases
    ( isDefaultReference
    , installData
    , getIndexPath
    , getGff
    , ensureDataPresent
    , findDataFiles
    ) where

import qualified Data.ByteString.Lazy as BL
import qualified Codec.Archive.Tar as Tar
import qualified Codec.Compression.GZip as GZip


import System.FilePath.Posix
import System.Directory
import System.IO.Error

import Control.Monad
import Control.Applicative ((<$>), (<|>))
import Control.Monad.IO.Class (liftIO)

import Utils.Network
import Utils.Bwa
import Configuration
import Output
import NGLess

defaultGenomes :: [String]
defaultGenomes =
                [ "hg19" -- Homo_sapiens
                , "mm10" -- Mus_musculus
                , "rn4" --  Rattus_norvegicus
                , "bosTau4" --  Bos_taurus
                , "canFam2" --Canis_familiaris
                , "dm3" --Drosophila_melanogaster
                , "ce10" --Caenorhabditis_elegans
                , "sacCer3" --Saccharomyces_cerevisiae
                ]
isDefaultReference :: String -> Bool
isDefaultReference =  (`elem` defaultGenomes)

getIndexPath :: FilePath -> FilePath
getIndexPath = (</> "Sequence/BWAIndex/genome.fa.gz")
getGff :: FilePath -> FilePath
getGff = (</> "Annotation/annot.gtf.gz")


downloadReference :: String -> FilePath -> NGLessIO ()
downloadReference ref destPath = do
    unless (isDefaultReference ref)
        (error "Expected reference data")
    baseURL <- nglessDataBaseURL
    let url = (baseURL </> ref <.> "tar.gz")
    outputListLno' InfoOutput ["Starting download from ", url]
    liftIO $ downloadFile url destPath
    outputLno' InfoOutput "Reference download completed!"


-- | Make sure that reference data is present, downloading it if necessary.
-- Returns the base path for the data.
ensureDataPresent :: String -> NGLessIO FilePath
ensureDataPresent ref = do
    p <- findDataFiles ref
    case p of
        Just p' -> return p'
        Nothing -> installData Nothing ref

-- | Installs reference data uncondictionally
-- When mode is Nothing, tries to install them in global directory, otherwise
-- installs it in the user directory
installData :: Maybe InstallMode -> String -> NGLessIO FilePath
installData Nothing ref = do
    p' <- globalDataDirectory
    canInstallGlobal <- liftIO $ do
        created <- (createDirectoryIfMissing False p' >> return True) `catchIOError` (\_ -> return False)
        if created
            then writable <$> getPermissions p'
            else return False
    if canInstallGlobal
        then installData (Just Root) ref
        else installData (Just User) ref
installData (Just mode) ref = do
    basedir <- if mode == Root
                then globalDataDirectory
                else userDataDirectory
    liftIO $ createDirectoryIfMissing True basedir
    let tarName = basedir </> ref <.> "tar.gz"
    downloadReference ref tarName
    liftIO $
        Tar.unpack basedir . Tar.read . GZip.decompress =<< BL.readFile tarName
    return (basedir </> ref)



-- | checks first user and then global data directories for <ref>.
-- The user directory is checked first to allow the user to override a
-- problematic global installation.
findDataFiles :: FilePath -> NGLessIO (Maybe FilePath)
findDataFiles ref = liftM2 (<|>)
    (findDataFilesIn ref User)
    (findDataFilesIn ref Root)

findDataFilesIn :: FilePath -> InstallMode -> NGLessIO (Maybe FilePath)
findDataFilesIn ref mode = do
    basedir <- if mode == Root
                    then globalDataDirectory
                    else userDataDirectory
    let refdir = basedir </> ref
    hasIndex <- hasValidIndex (getIndexPath refdir)
    return (if hasIndex
                then Just refdir
                else Nothing)

