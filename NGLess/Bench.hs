{- Copyright 2016
 - Licence: MIT -}
import Criterion.Main



import qualified Data.Conduit.List as CL
import qualified Data.Conduit.Binary as CB
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Conduit as C
import qualified Data.Text as T
import           Data.Conduit ((=$=), ($$))
import           Control.DeepSeq (NFData)

import Control.Monad.Trans.Resource (runResourceT)

import NGLess (NGLessIO, testNGLessIO)
import Configuration (setupTestConfiguration)


import Interpretation.Map (_samStats)
import Interpretation.Count (performCount, MMMethod(..), loadAnnotator, loadFunctionalMap, CountOpts(..), annotationRule, AnnotationIntersectionMode(..), AnnotationMode(..))
import Interpret (interpret)
import Parse (parsengless)
import Language (Script(..))
import Data.Sam (readSamLine, readSamGroupsC)
import Data.FastQ (statsFromFastQ, parseFastQ, FastQEncoding(..), ShortRead(..))
import Substrim (substrim)

nfNGLessIO :: (NFData a) => NGLessIO a -> Benchmarkable
nfNGLessIO = nfIO . testNGLessIO

nfNGLessScript :: T.Text -> Benchmarkable
nfNGLessScript sc = case parsengless "bench" False sc of
    Left err -> error (show err)
    Right expr -> nfNGLessIO $ interpret [] . nglBody $ expr


nfRIO = nfIO . runResourceT
countRights = loop (0 :: Int)
    where
        loop !i = C.await >>= \case
            Nothing -> return i
            Just (Right _) -> loop (i+1)
            _ -> loop i

exampleSR :: ShortRead
exampleSR = head . parseFastQ SangerEncoding $ BL.fromChunks
                ["@SRR867735.1 HW-ST997:253:C16APACXX:7:1101:2971:1948/1\n"
                ,"NCCGCTGCTCGGGATCAAGACATACCGCGGGGGGAGGGGAGCGGGACCAC\n"
                ,"+\n"
                ,"#11ABDD6DFBDFHEGHDDGFFFHE?@GEEGA##################\n"]


count= loop (0 :: Int)
    where
        loop !i = C.await >>= \case
            Nothing -> return i
            Just _ -> loop (i+1)

basicCountOpts = CountOpts
        { optFeatures = []
        , optIntersectMode = annotationRule IntersectStrict
        , optStrandSpecific = False
        , optKeepAmbiguous = True
        , optMinCount = 0.0
        , optMMMethod = MMDist1
        , optDelim = "\t"
        }

main = setupTestConfiguration >> defaultMain [
    bgroup "sam-stats"
        [ bench "sample" $ nfNGLessIO (_samStats "test_samples/sample.sam")
        ]
    ,bgroup "fastq"
        [ bench "fastqStats" $ nfNGLessIO (statsFromFastQ "test_samples/sample.fq.gz")
        , bench "preprocess" $ nfNGLessScript "p = fastq('test_samples/sample.fq.gz')\npreprocess(p) using |r|:\n  r = substrim(r, min_quality=26)\n"
        , bench "preprocess-pair" $ nfNGLessScript
                "p = paired('test_samples/sample.fq.gz', 'test_samples/sample.fq.gz')\npreprocess(p) using |r|:\n  r = substrim(r, min_quality=26)\n"
        , bench "substrim" $ nf (substrim 30) exampleSR
        ]
    ,bgroup "parse-sam"
        [ bench "readSamLine" $ nfRIO (CB.sourceFile "test_samples/sample.sam" =$= CB.lines =$= CL.map readSamLine $$ countRights)
        , bench "samGroups" $ nfNGLessIO (CB.sourceFile "test_samples/sample.sam" =$= CB.lines =$= readSamGroupsC $$ count)
        ]
    ,bgroup "count"
        [ bench "load-map"      $ nfNGLessIO (loadFunctionalMap   "test_samples/functional.map" ["ko", "cog"])
        , bench "annotate-seqname" . nfNGLessIO $ do
                    amap <- loadAnnotator (AnnotateFunctionalMap "test_samples/functional.map") basicCountOpts
                    performCount "test_samples/sample.sam" "testing" amap basicCountOpts
        ]
    ]
