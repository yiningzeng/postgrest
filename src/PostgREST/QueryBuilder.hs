{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# OPTIONS_GHC -fno-warn-orphans  #-}
{-|
Module      : PostgREST.QueryBuilder
Description : PostgREST SQL queries generating functions.

This module provides functions to consume data types that
represent database objects (e.g. Relation, Schema) and SqlFragment
to produce SqlQuery type outputs.
-}
module PostgREST.QueryBuilder (
    requestToQuery
  , requestToCountQuery
  , requestToCallProcQuery
  , setLocalQuery
  , setLocalSearchPathQuery
  ) where

import qualified Data.Set as S

import Data.Text (intercalate, unwords)
import Data.Tree (Tree (..))

import Data.Maybe

import PostgREST.QueryBuilder.Private
import PostgREST.RangeQuery           (allRange, rangeLimit,
                                       rangeOffset)
import PostgREST.Types
import Protolude                      hiding (cast, intercalate,
                                       replace)

requestToCountQuery :: Schema -> DbRequest -> SqlQuery
requestToCountQuery _ (DbMutate _) = witness
requestToCountQuery schema (DbRead (Node (Select{where_=logicForest}, (mainTbl, _, _, _, _)) _)) =
 unwords [
   "SELECT pg_catalog.count(*)",
   "FROM ", fromQi qi,
    ("WHERE " <> intercalate " AND " (map (pgFmtLogicTree qi) logicForest)) `emptyOnFalse` null logicForest
   ]
 where
   qi = removeSourceCTESchema schema mainTbl

requestToQuery :: Schema -> Bool -> DbRequest -> SqlQuery
requestToQuery schema isParent (DbRead (Node (Select colSelects tbl tblAlias implJoins logicForest joinConditions_ ordts range, _) forest)) =
  unwords [
    "SELECT " <> intercalate ", " (map (pgFmtSelectItem qi) colSelects ++ selects),
    "FROM " <> intercalate ", " (tabl : implJs),
    unwords joins,
    ("WHERE " <> intercalate " AND " (map (pgFmtLogicTree qi) logicForest ++ map pgFmtJoinCondition joinConditions_))
      `emptyOnFalse` (null logicForest && null joinConditions_),
    ("ORDER BY " <> intercalate ", " (map (pgFmtOrderTerm qi) ordts)) `emptyOnFalse` null ordts,
    ("LIMIT " <> maybe "ALL" show (rangeLimit range) <> " OFFSET " <> show (rangeOffset range)) `emptyOnFalse` (isParent || range == allRange) ]

  where
    implJs = fromQi . QualifiedIdentifier schema <$> implJoins
    mainQi = removeSourceCTESchema schema tbl
    tabl = fromQi mainQi <> maybe mempty (\a -> " AS " <> pgFmtIdent a) tblAlias
    qi = maybe mainQi (QualifiedIdentifier mempty) tblAlias

    (joins, selects) = foldr getQueryParts ([],[]) forest

    getQueryParts :: Tree ReadNode -> ([SqlFragment], [SqlFragment]) -> ([SqlFragment], [SqlFragment])
    getQueryParts (Node n@(_, (name, Just Relation{relType=Child,relTable=Table{tableName=table}}, alias, _, _)) forst) (j,s) = (j,sel:s)
      where
        sel = "COALESCE(("
           <> "SELECT json_agg(" <> pgFmtIdent table <> ".*) "
           <> "FROM (" <> subquery <> ") " <> pgFmtIdent table
           <> "), '[]') AS " <> pgFmtIdent (fromMaybe name alias)
           where subquery = requestToQuery schema False (DbRead (Node n forst))
    getQueryParts (Node n@(_, (name, Just Relation{relType=Parent,relTable=Table{tableName=table}}, alias, _, _)) forst) (j,s) = (joi:j,sel:s)
      where
        aliasOrName = fromMaybe name alias
        localTableName = pgFmtIdent $ table <> "_" <> aliasOrName
        sel = "row_to_json(" <> localTableName <> ".*) AS " <> pgFmtIdent aliasOrName
        joi = " LEFT JOIN LATERAL( " <> subquery <> " ) AS " <> localTableName <> " ON TRUE "
          where subquery = requestToQuery schema True (DbRead (Node n forst))
    getQueryParts (Node n@(_, (name, Just Relation{relType=Many,relTable=Table{tableName=table}}, alias, _, _)) forst) (j,s) = (j,sel:s)
      where
        sel = "COALESCE (("
           <> "SELECT json_agg(" <> pgFmtIdent table <> ".*) "
           <> "FROM (" <> subquery <> ") " <> pgFmtIdent table
           <> "), '[]') AS " <> pgFmtIdent (fromMaybe name alias)
           where subquery = requestToQuery schema False (DbRead (Node n forst))
    --the following is just to remove the warning
    --getQueryParts is not total but requestToQuery is called only after addJoinConditions which ensures the only
    --posible relations are Child Parent Many
    getQueryParts _ _ = witness
requestToQuery schema _ (DbMutate (Insert mainTbl iCols onConflct putConditions returnings)) =
  unwords [
    "WITH " <> normalizedBody,
    "INSERT INTO ", fromQi qi, if S.null iCols then " " else "(" <> cols <> ")",
    unwords [
      "SELECT " <> cols <> " FROM",
      "json_populate_recordset", "(null::", fromQi qi, ", " <> selectBody <> ") _",
      -- Only used for PUT
      ("WHERE " <> intercalate " AND " (pgFmtLogicTree (QualifiedIdentifier "" "_") <$> putConditions)) `emptyOnFalse` null putConditions],
    maybe "" (\(oncDo, oncCols) -> (
      "ON CONFLICT(" <> intercalate ", " (pgFmtIdent <$> oncCols) <> ") " <> case oncDo of
      IgnoreDuplicates ->
        "DO NOTHING"
      MergeDuplicates  ->
        if S.null iCols
           then "DO NOTHING"
           else "DO UPDATE SET " <> intercalate ", " (pgFmtIdent <> const " = EXCLUDED." <> pgFmtIdent <$> S.toList iCols)
                                   ) `emptyOnFalse` null oncCols) onConflct,
    ("RETURNING " <> intercalate ", " (map (pgFmtColumn qi) returnings)) `emptyOnFalse` null returnings]
  where
    qi = QualifiedIdentifier schema mainTbl
    cols = intercalate ", " $ pgFmtIdent <$> S.toList iCols
requestToQuery schema _ (DbMutate (Update mainTbl uCols logicForest returnings)) =
  if S.null uCols
    then "WITH " <> ignoredBody <> "SELECT null WHERE false" -- if there are no columns we cannot do UPDATE table SET {empty}, it'd be invalid syntax
    else
      unwords [
        "WITH " <> normalizedBody,
        "UPDATE " <> fromQi qi <> " SET " <> cols,
        "FROM (SELECT * FROM json_populate_recordset", "(null::", fromQi qi, ", " <> selectBody <> ")) _ ",
        ("WHERE " <> intercalate " AND " (pgFmtLogicTree qi <$> logicForest)) `emptyOnFalse` null logicForest,
        ("RETURNING " <> intercalate ", " (pgFmtColumn qi <$> returnings)) `emptyOnFalse` null returnings
        ]
  where
    qi = QualifiedIdentifier schema mainTbl
    cols = intercalate ", " (pgFmtIdent <> const " = _." <> pgFmtIdent <$> S.toList uCols)
requestToQuery schema _ (DbMutate (Delete mainTbl logicForest returnings)) =
  unwords [
    "WITH " <> ignoredBody,
    "DELETE FROM ", fromQi qi,
    ("WHERE " <> intercalate " AND " (map (pgFmtLogicTree qi) logicForest)) `emptyOnFalse` null logicForest,
    ("RETURNING " <> intercalate ", " (map (pgFmtColumn qi) returnings)) `emptyOnFalse` null returnings
    ]
  where
    qi = QualifiedIdentifier schema mainTbl

requestToCallProcQuery :: QualifiedIdentifier -> [PgArg] -> Bool -> Bool -> SqlQuery
requestToCallProcQuery qi pgArgs returnsScalar paramsAsSingleObject =
  unwords [
    "WITH",
    argsRecord,
    sourceBody ]
  where
    (argsRecord, args)
      | null pgArgs = (ignoredBody, "")
      | paramsAsSingleObject = ("_args_record AS (SELECT NULL)", "$1::json")
      | otherwise = (
          unwords [
            normalizedBody <> ",",
            "_args_record AS (",
              "SELECT * FROM json_to_recordset(" <> selectBody <> ") AS _(" <>
                intercalate ", " ((\a -> pgFmtIdent (pgaName a) <> " " <> pgaType a) <$> pgArgs) <> ")",
            ")"]
         , intercalate ", " ((\a -> pgFmtIdent (pgaName a) <> " := _args_record." <> pgFmtIdent (pgaName a)) <$> pgArgs))

    sourceBody :: SqlFragment
    sourceBody
      | paramsAsSingleObject || null pgArgs =
          if returnsScalar
            then "SELECT " <> callIt <> " AS _scalar_res"
            else "SELECT * FROM " <> callIt
      | otherwise =
          if returnsScalar
            then "SELECT " <> callIt <> " AS _scalar_res FROM _args_record"
            else unwords [
              "SELECT _.*",
              "FROM _args_record,",
              "LATERAL ( SELECT * FROM " <> callIt <> " ) _" ]

    callIt :: SqlFragment
    callIt = fromQi qi <> "(" <> args <> ")"

setLocalQuery :: Text -> (Text, Text) -> SqlQuery
setLocalQuery prefix (k, v) =
  "SET LOCAL " <> pgFmtIdent (prefix <> k) <> " = " <> pgFmtLit v <> ";"

setLocalSearchPathQuery :: [Text] -> SqlQuery
setLocalSearchPathQuery vals =
  "SET LOCAL search_path = " <> intercalate ", " (pgFmtLit <$> vals) <> ";"
