------------------------------------------------------------------------------
-- Copyright 2012-2021, Microsoft Research, Daan Leijen.
--
-- This is free software; you can redistribute it and/or modify it under the
-- terms of the Apache License, Version 2.0. A copy of the License can be
-- found in the LICENSE file at the root of this distribution.
-----------------------------------------------------------------------------
module Syntax.RangeMap( RangeMap, RangeInfo(..), NameInfo(..)
                      , rangeMapNew
                      , rangeMapInsert
                      , rangeMapSort
                      , rangeMapLookup
                      , rangeMapAppend
                      , mangle
                      , mangleConName
                      , mangleTypeName
                      ) where

import Lib.Trace
import Data.Char    ( isSpace )
import Common.Failure
import Data.List    (sortBy, groupBy)
import Lib.PPrint
import Common.Range
import Common.Name
import Common.NamePrim (nameUnit, nameListNil, isNameTuple)
import Common.File( startsWith )
import Type.Type
import Kind.Kind
import Type.TypeVar
import Type.Pretty()

newtype RangeMap = RM [(Range,RangeInfo)]

mangleConName :: Name -> Name
mangleConName name
  = prepend "con " name

mangleTypeName :: Name -> Name
mangleTypeName name
  = prepend "type " name

mangle :: Name -> Type -> Name
mangle name tp
  = name
  -- newQualified (nameModule name) (nameId name ++ ":" ++ compress (show tp))
  where
    compress cs
      = case cs of
          [] -> []
          (c:cc) ->
            if (isSpace c)
             then ' ' : compress (dropWhile isSpace cc)
             else c : compress cc

data RangeInfo
  = Decl String Name Name  -- alias, type, cotype, rectype, fun, val
  | Block String           -- type, kind, pattern
  | Error Doc
  | Warning Doc
  | Id Name NameInfo [Doc] Bool  -- qualified name, info, extra doc (from implicits), is this the definition?
  | Implicits Doc                -- inferred implicit arguments

data NameInfo
  = NIValue   Type
  | NICon     Type
  | NITypeCon Kind
  | NITypeVar Kind
  | NIModule
  | NIKind


instance Show RangeInfo where
  show ri
    = case ri of
        Decl kind nm1 nm2 -> "Decl " ++ kind ++ " " ++ show nm1 ++ " " ++ show nm2
        Block kind        -> "Block " ++ kind
        Error doc         -> "Error"
        Warning doc       -> "Warning"
        Id name info _ isDef -> "Id " ++ show name ++ (if isDef then " (def)" else "")
        Implicits doc        -> "Implicits " ++ show doc

instance Enum RangeInfo where
  fromEnum r
    = case r of
        Decl _ name _    -> 0
        Block _          -> 10
        Id name info _ _ -> 20
        Implicits _      -> 25
        Warning _        -> 40
        Error _          -> 50

  toEnum i
    = failure "Syntax.RangeMap.RangeInfo.toEnum"

penalty :: Name -> Int
penalty name
  = if (nameModule name == "std/core/hnd")
     then 10 else 0

-- (inverse) priorities
instance Enum NameInfo where
  fromEnum ni
    = case ni of
        NIValue _   -> 1
        NICon   _   -> 2
        NITypeCon _ -> 3
        NITypeVar _ -> 4
        NIModule    -> 5
        NIKind      -> 6

  toEnum i
    = failure "Syntax.RangeMap.NameInfo.toEnum"

isHidden ri
  = case ri of
      Decl kind nm1 nm2       -> isHiddenName nm1
      Id name info docs isDef -> isHiddenName name
      _ -> False


rangeMapNew :: RangeMap
rangeMapNew
  = RM []

cut r
  = (makeRange (rangeStart r) (rangeStart r))

rangeMapInsert :: Range -> RangeInfo -> RangeMap -> RangeMap
rangeMapInsert r info (RM rm)
  = -- trace ("rangemap insert: " ++ show r ++ ": " ++ show info) $
    if isHidden info
     then RM rm
    else if beginEndToken info
     then RM ((r,info):(makeRange (rangeEnd r) (rangeEnd r),info):rm)
     else RM ((r,info):rm)
  where
    beginEndToken info
      = case info of
          Id name _ _ _ -> (name == nameUnit || name == nameListNil || isNameTuple name)
          _ -> False

rangeMapAppend :: RangeMap -> RangeMap -> RangeMap
rangeMapAppend (RM rm1) (RM rm2)
  = RM (rm1 ++ rm2)

rangeMapSort :: RangeMap -> RangeMap
rangeMapSort (RM rm)
  = RM (sortBy (\(r1,_) (r2,_) -> compare r1 r2) rm)

rangeMapLookup :: Range -> RangeMap -> ([(Range,RangeInfo)],RangeMap)
rangeMapLookup r (RM rm)
  = let (rinfos,rm') = span startsAt (dropWhile isBefore rm)
    in -- trace ("lookup: " ++ show r ++ ": " ++ show rinfos) $
       (prioritize rinfos, RM rm')
  where
    pos = rangeStart r
    isBefore (rng,_)  = rangeStart rng < pos
    startsAt (rng,_)  = rangeStart rng == pos

    prioritize rinfos
      = let idocs = concatMap (\(_,rinfo) -> case rinfo of
                                               Implicits doc -> [doc]
                                               _             -> []) rinfos
        in map (mergeDocs idocs) $
           map last $ groupBy eq $ sortBy cmp $
           filter (not . isImplicits . snd) rinfos
      where
        isImplicits (Implicits _) = True
        isImplicits _             = False

        eq (_,ri1) (_,ri2)  = (EQ == compare ((fromEnum ri1) `div` 10) ((fromEnum ri2) `div` 10))
        cmp (_,ri1) (_,ri2) = compare (fromEnum ri1) (fromEnum ri2)

        -- merge implicit documentation into identifiers
        mergeDocs ds (rng, Id name info docs isDef) = (rng, Id name info (docs ++ ds) isDef)
        mergeDocs ds x = x


instance HasTypeVar RangeMap where
  sub `substitute` (RM rm)
    = RM (map (\(r,ri) -> (r,sub `substitute` ri)) rm)

  ftv (RM rm)
    = ftv (map snd rm)

  btv (RM rm)
    = btv (map snd rm)

instance HasTypeVar RangeInfo where
  sub `substitute` (Id nm info docs isdef)  = Id nm (sub `substitute` info) docs isdef
  sub `substitute` ri                       = ri

  ftv (Id nm info _ _) = ftv info
  ftv ri               = tvsEmpty

  btv (Id nm info _ _) = btv info
  btv ri               = tvsEmpty

instance HasTypeVar NameInfo where
  sub `substitute` ni
    = case ni of
        NIValue tp  -> NIValue (sub `substitute` tp)
        NICon tp    -> NICon (sub `substitute` tp)
        _           -> ni

  ftv ni
    = case ni of
        NIValue tp  -> ftv tp
        NICon tp    -> ftv tp
        _           -> tvsEmpty

  btv ni
    = case ni of
        NIValue tp  -> btv tp
        NICon tp    -> btv tp
        _           -> tvsEmpty
