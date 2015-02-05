{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}

-- Module      : Rifactor.Capacity
-- Copyright   : (c) 2015 Knewton, Inc <se@knewton.com>
--               (c) 2015 Tim Dysinger <tim@dysinger.net> (contributor)
-- License     : Apache 2.0 http://opensource.org/licenses/Apache-2.0
-- Maintainer  : Tim Dysinger <tim@dysinger.net>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

module Rifactor.Capacity where

import BasePrelude hiding (getEnv)
import Control.Lens
import Control.Monad.IO.Class ()
import Network.AWS.EC2
import Rifactor.AWS
import Rifactor.Types

capacity :: Reserved -> Maybe (Double, Double)
capacity r
  | isNothing (r ^. reReserved ^. ri1InstanceCount) ||
      isNothing (r ^. reReserved ^. ri1InstanceType) = Nothing
capacity r =
  let (Just rCount) = r ^. reReserved ^. ri1InstanceCount
      (Just rType) = r ^. reReserved ^. ri1InstanceType
      (_,rFactor) = instanceClass rType
  in let rCapacity =
           (realToFrac rCount) *
           (rFactor :: Double)
         rOldUsed =
           (realToFrac (length (r ^. reInstances))) *
           (rFactor :: Double)
         rNewUsed =
           foldl (\a i ->
                    a +
                    ((instanceClass (i ^. i1InstanceType)) ^.
                     _2))
                 (0 :: Double)
                 (r ^. reNewInstances)
     in Just (rCapacity,rOldUsed + rNewUsed)

isInstanceTypeMatch :: Reserved -> OnDemand -> Bool
isInstanceTypeMatch r _
  | isNothing (r ^. reReserved ^. ri1InstanceCount) ||
      isNothing (r ^. reReserved ^. ri1InstanceType) = False
isInstanceTypeMatch r i =
  let (Just rType) = r ^. reReserved ^. ri1InstanceType
      (iGroup,iFactor) =
        instanceClass (i ^. odInstance ^. i1InstanceType)
      (rGroup,_) =
        instanceClass rType :: (InstanceGroup,Double)
  in rGroup == iGroup &&
     case (capacity r) of
       Nothing -> False
       Just (total,used) ->
         (total - used) >=
         iFactor
