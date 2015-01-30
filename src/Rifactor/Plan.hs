{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- Module      : Rifactor.Plan
-- Copyright   : (c) 2015 Knewton, Inc <se@knewton.com>
--               (c) 2015 Tim Dysinger <tim@dysinger.net> (contributor)
-- License     : Apache 2.0 http://opensource.org/licenses/Apache-2.0
-- Maintainer  : Tim Dysinger <tim@dysinger.net>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

module Rifactor.Plan where

import           BasePrelude hiding (getEnv)
import           Control.Lens
import           Control.Monad.IO.Class ()
import           Control.Monad.Trans.AWS hiding (accessKey, secretKey)
import           Control.Monad.Trans.Resource (runResourceT)
import qualified Data.Aeson as A
import qualified Data.ByteString.Char8 as B
import           Data.Conduit (($$))
import qualified Data.Conduit.Attoparsec as C (sinkParser)
import qualified Data.Conduit.Binary as C (sourceFile)
import qualified Data.Text as T
import           Network.AWS.Data (toText)
import           Network.AWS.EC2
import           Rifactor.Types
import           System.IO (stdout)

plan :: Options -> IO ()
plan opts =
  do config <-
       runResourceT $
       C.sourceFile (opts ^. file) $$
       C.sinkParser A.json
     case (A.fromJSON config :: A.Result Config) of
       (A.Error err) -> putStrLn err >> exitFailure
       (A.Success cfg) ->
         do lgr <-
              newLogger (if (opts ^. verbose)
                            then Trace
                            else Info)
                        stdout
            dummyEnv <-
              getEnv NorthVirginia
                     (FromKeys (AccessKey B.empty)
                               (SecretKey B.empty))
            es <- initEnvs cfg lgr
            pending <-
              runAWST dummyEnv (checkPendingModifications es)
            case pending of
              (Left err) -> print err >> exitFailure
              _ ->
                do results <-
                     runAWST dummyEnv (fetchFromAmazon es)
                   case results of
                     (Left err) -> print err >> exitFailure
                     (Right xs) ->
                       do let (reserved,_) = interpret xs
                          traverse_ print
                                    (filter (\x -> isMoveReserved x ||
                                                    isSplitReserved x)
                                            reserved)

initEnvs :: Config -> Logger -> IO [Env]
initEnvs cfg lgr =
  for [(a,r) | r <- (cfg ^. regions)
             , a <- (cfg ^. accounts)]
      (\(a,r) ->
         (getEnv r
                 (FromKeys (AccessKey (B.pack (a ^. accessKey)))
                           (SecretKey (B.pack (a ^. secretKey)))) <&>
          (envLogger .~ lgr)))

checkPendingModifications :: [Env] -> AWS ()
checkPendingModifications =
  traverse_ (\e ->
               runAWST e
                       (do rims <-
                             view drimrReservedInstancesModifications <$>
                             send (describeReservedInstancesModifications &
                                   (drimFilters .~
                                    [filter' "status" &
                                     fValues .~
                                     [T.pack "processing"]]))
                           if null rims
                              then pure ()
                              else error "There are pending RI modifications."))

fetchFromAmazon :: [Env] -> AWS ([Reserved],[OnDemand])
fetchFromAmazon es =
  pure (,) <*> fetchReservedInstances es <*> fetchInstances es

fetchReservedInstances :: [Env] -> AWS [Reserved]
fetchReservedInstances =
  liftA concat .
  traverse (\e ->
              do xs <-
                   hoistEither =<<
                   runAWST e
                           (view drirReservedInstances <$>
                            send (describeReservedInstances & driFilters .~
                                  [filter' "state" &
                                   fValues .~
                                   [toText RISActive]]))
                 pure (map (Reserved e) xs))

fetchInstances :: [Env] -> AWS [OnDemand]
fetchInstances =
  liftA concat .
  traverse (\e ->
              do xs <-
                   hoistEither =<<
                   runAWST e
                           (view dirReservations <$>
                            send (describeInstances & di1Filters .~
                                  [filter' "instance-state-name" &
                                   fValues .~
                                   [toText ISNRunning]]))
                 pure (map OnDemand (concatMap (view rInstances) xs)))

merge :: (Reserved -> OnDemand -> Bool)
      -> (Reserved -> [Instance] -> Reserved)
      -> ([Reserved],[OnDemand])
      -> ([Reserved],[OnDemand])
merge isMatching convert (reserved,nodes) =
  let (unmatchedReserved,otherReserved) =
        partition isReserved reserved
  in go otherReserved (unmatchedReserved,nodes)
  where go rs ([],ys) = (rs,ys)
        go rs (xs,[]) = (rs ++ xs,[])
        go rs ((x:xs),ys) =
          case (partition (isMatching x) ys) of
            ([],unmatched) ->
              go (x : rs)
                 (xs,unmatched)
            (matched,unmatched) ->
              let count =
                    fromMaybe 0 (x ^?! reReservedInstances ^. ri1InstanceCount)
                  (used,unused) =
                    splitAt count matched
                  uis =
                    map (\(OnDemand i) -> i) used
              in if length used == 0
                    then go (x : rs)
                            (xs,ys)
                    else go (convert x uis :
                             rs)
                            (xs,(unmatched ++ unused))

interpret :: ([Reserved],[OnDemand])
          -> ([Reserved],[OnDemand])
interpret = match . move . split . combine . resize

-- | Match unused ReservedInstances with OnDemand nodes that
-- match by instance type, network type & availability zone.
match :: ([Reserved],[OnDemand]) -> ([Reserved],[OnDemand])
match =
  merge isPerfectMatch convertToUsed
  where isPerfectMatch (Reserved _ r) (OnDemand i) =
          (r ^. ri1AvailabilityZone == i ^. i1Placement ^. pAvailabilityZone) &&
          (r ^. ri1InstanceType == i ^? i1InstanceType)
        -- TODO Add network type (Classic vs VPN)
        isPerfectMatch _ _ = False
        convertToUsed r uis =
          (UsedReserved (r ^. reEnv)
                        (r ^?! reReservedInstances)
                        uis)

-- | Move unused ReservedInstances around to accommidate nodes that
-- match by instance type.
move :: ([Reserved],[OnDemand]) -> ([Reserved],[OnDemand])
move =
  merge isWorkableMatch convertToMove
  where isWorkableMatch (Reserved _ r) (OnDemand i) =
          (r ^. ri1InstanceType == i ^? i1InstanceType)
        isWorkableMatch _ _ = False
        convertToMove r uis =
          (MoveReserved (r ^. reEnv)
                        (r ^?! reReservedInstances)
                        uis)

-- | Split used ReservedInstances up that have remaining capacity but
-- still have slots left for nodes with the same instance type but
-- with other availability zones or network types.
split :: ([Reserved],[OnDemand]) -> ([Reserved],[OnDemand])
split = id

-- | Combine Reserved Instances that aren't used with other
-- ReservedInstances with the same stop date (& hour).
combine :: ([Reserved],[OnDemand]) -> ([Reserved],[OnDemand])
combine = id

-- | Resize Reserved Instances that have capacity if we can accomidate
-- nodes of different instance types.
resize :: ([Reserved],[OnDemand]) -> ([Reserved],[OnDemand])
resize = id
