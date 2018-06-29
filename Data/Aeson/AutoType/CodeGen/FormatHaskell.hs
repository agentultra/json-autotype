{-# LANGUAGE CPP                 #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGuaGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns        #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGuaGE DeriveGeneric       #-}
{-# LANGuaGE FlexibleContexts    #-}
-- | Formatting type declarations and class instances for inferred types. 
module Data.Aeson.AutoType.Format(
  displaySplitTypes, splitTypeByLabel, unificationCandidates,
  unifyCandidates,
  normalizeTypeName,
  capitalize
) where

import           Control.Arrow             ((&&&))
import           Control.Applicative       ((<$>), (<*>))
import           Control.Lens.TH
import           Control.Lens
import           Control.Monad             (forM)
import           Control.Exception(assert)
import qualified Data.HashMap.Strict        as Map
import           Data.Monoid
import qualified Data.Set                   as Set
import qualified Data.Text                  as Text
import           Data.Text                 (Text)
import           Data.Set                  (Set )
import           Data.List                 (foldl1')
import           Data.Char                 (isAlpha, isDigit)
import           Control.Monad.State.Class
import           Control.Monad.State.Strict(State, runState)
import qualified Data.Graph          as Graph
import           GHC.Generics              (Generic)

import           Data.Aeson.AutoType.Type
import           Data.Aeson.AutoType.Extract
import           Data.Aeson.AutoType.Util  ()

--import           Debug.Trace -- DEBUG
trace _ x = x

fst3 ::  (t, t1, t2) -> t
fst3 (a, _b, _c) = a

data DeclState l = DeclState { _decls   :: [Text]
                             , _counter :: Int
                             , _lang    :: l
                             }
  deriving (Eq, Show, Ord, Generic)

makeLenses ''DeclState

type DeclM = State DeclState

type Map k v = Map.HashMap k v 

stepM :: DeclM Int
stepM = counter %%= (\i -> (i, i+1))

tShow :: (Show a) => a -> Text
tShow = Text.pack . show 

-- | Wrap a type alias.
wrapAlias :: Text -> Text -> Text
wrapAlias identifier contents = Text.unwords ["type", identifier, "=", contents]

-- | Wrap a data type declaration
wrapDecl ::  Text -> Text -> Text
wrapDecl identifier contents = Text.unlines [header, contents, "  } deriving (Show,Eq,GHC.Generics.Generic)"]
                                            --,"\nderiveJSON defaultOptions ''" `Text.append` identifier]
  where
    header = Text.concat ["data ", identifier, " = ", identifier, " { "]

-- | Explanatory type alias for making declarations
-- First element of the triple is original JSON identifier,
-- second element of the triple is the mapped identifier name in Haskell.
-- third element of the triple shows the type in a formatted way
type MappedKey = (Text, Text, Text, Bool)

-- | Make ToJSON declaration, given identifier (object name in Haskell) and mapping of its keys
-- from JSON to Haskell identifiers *in the same order* as in *data type declaration*.
makeFromJSON ::  Text -> [MappedKey] -> Text
makeFromJSON identifier contents =
  Text.unlines [
      Text.unwords ["instance FromJSON", identifier, "where"]
    , Text.unwords ["  parseJSON (Object v) =", makeParser identifier contents]
    , "  parseJSON _          = mzero" ]
  where
    makeParser identifier [] = Text.unwords ["return ", identifier]
    makeParser identifier _  = Text.unwords [identifier, "<$>", inner]
    inner                    = " <*> " `Text.intercalate`
                                  map takeValue contents
    takeValue (jsonId, _, ty, True ) = Text.concat ["v .:? \"", jsonId, "\""] -- nullable types
    takeValue (jsonId, _, _ , False) = Text.concat ["v .:  \"", jsonId, "\""]
-- Contents example for wrapFromJSON:
-- " <$>
--"                           v .: "hexValue"  <*>
--"                           v .: "colorName\""

-- | Make ToJSON declaration, given identifier (object name in Haskell) and mapping of its keys
-- from JSON to Haskell identifiers in the same order as in declaration
makeToJSON :: Text -> [MappedKey] -> Text
makeToJSON identifier contents =
    Text.unlines [
        Text.concat ["instance ToJSON ", identifier, " where"]
      , Text.concat ["  toJSON     (", identifier, " {", wildcard, "}) = object [", inner ", ", "]"]
#if MIN_VERSION_aeson(0,11,0)
      , maybeToEncoding
#endif
      ]
  where
    maybeToEncoding | null contents = ""
                    | otherwise     =
                        Text.concat ["  toEncoding (", identifier, " {", wildcard, "}) = pairs  (", inner "<>", ")"]
    wildcard | null contents = ""
             | otherwise     = ".."
    inner separator = separator `Text.intercalate`
                      map putValue contents
    putValue (jsonId, haskellId, _typeText, _nullable) = Text.unwords [escapeText jsonId, ".=", haskellId]
    escapeText = Text.pack . show . Text.unpack
-- Contents example for wrapToJSON
--"hexValue"  .= hexValue
--                                        ,"colorName" .= colorName]


-- | Makes a generic identifier name.
genericIdentifier :: DeclM Text
genericIdentifier = do
  i <- stepM
  return $! "Obj" `Text.append` tShow i

-- * Printing a single data type declaration
newDecl :: Text -> [(Text, Type)] -> DeclM Text
newDecl identifier kvs = do attrs <- forM kvs $ \(k, v) -> do
                              formatted <- formatType v
                              return (k, normalizeFieldName identifier k, formatted, isNullable v)
                            let decl = Text.unlines [wrapDecl     identifier $ fieldDecls attrs
                                                    ,""
                                                    ,makeFromJSON identifier              attrs
                                                    ,""
                                                    ,makeToJSON   identifier              attrs]
                            addDecl decl
                            return identifier
  where
    fieldDecls attrList = Text.intercalate ",\n" $ map fieldDecl attrList
    fieldDecl :: (Text, Text, Text, Bool) -> Text
    fieldDecl (_jsonName, haskellName, fType, _nullable) = Text.concat [
                                                             "    ", haskellName, " :: ", fType]

addDecl decl = decls %%= (\ds -> ((), decl:ds))

-- | Add new type alias for Array type
newAlias :: Text -> Type -> DeclM Text
newAlias identifier content = do formatted <- formatType content
                                 addDecl $ Text.unlines [wrapAlias identifier formatted]
                                 return identifier

-- | Convert a JSON key name given by second argument,
-- from within a dictionary keyed with first argument,
-- into a name of Haskell record field (hopefully distinct from other such selectors.)
normalizeFieldName ::  Text -> Text -> Text
normalizeFieldName identifier = escapeKeywords             .
                                uncapitalize               .
                                (normalizeTypeName identifier `Text.append`) .
                                normalizeTypeName

keywords ::  Set Text
keywords = Set.fromList ["type", "data", "module", "class", "where", "let", "do"]

escapeKeywords ::  Text -> Text
escapeKeywords k | k `Set.member` keywords = k `Text.append` "_"
escapeKeywords k                           = k

-- | Format the type within DeclM monad, that records
-- the separate declarations on which this one is dependent.
formatType :: Type -> DeclM Text
formatType  TString                          = return "Text"
formatType  TNum                             = return "Double"
formatType  TBool                            = return "Bool"
formatType (TLabel l)                        = return $ normalizeTypeName l
formatType (TUnion u)                        = wrap <$> case length nonNull of
                                                          0 -> return emptyTypeRepr
                                                          1 -> formatType $ head nonNull
                                                          _ -> Text.intercalate ":|:" <$> mapM formatType nonNull
  where
    nonNull       = Set.toList $ Set.filter (TNull /=) u
    wrap                                :: Text -> Text
    wrap   inner  | TNull `Set.member` u = Text.concat ["(Maybe (", inner, "))"]
                  | otherwise            =                          inner
formatType (TArray a)                        = do inner <- formatType a
                                                  return $ Text.concat ["[", inner, "]"]
formatType (TObj   o)                        = do ident <- genericIdentifier
                                                  newDecl ident d
  where
    d = Map.toList $ unDict o 
formatType  e | e `Set.member` emptySetLikes = return emptyTypeRepr
formatType  t                                = return $ "ERROR: Don't know how to handle: " `Text.append` tShow t

emptyTypeRepr :: Text
emptyTypeRepr = "(Maybe Value)" -- default, accepts future extension where we found no data

runDecl ::  Lang -> DeclM a -> Text
runDecl lang decl = Text.unlines $ finalState ^. decls
  where
    initialState    = DeclState lang [] 1
    (_, finalState) = runState decl initialState

-- * Splitting object types by label for unification.
type TypeTree    = Map Text [Type]

type TypeTreeM a = State TypeTree a

addType :: Text -> Type -> TypeTreeM ()
addType label typ = modify $ Map.insertWith (++) label [typ]

splitTypeByLabel' :: Text -> Type -> TypeTreeM Type
splitTypeByLabel' _  TString   = return TString
splitTypeByLabel' _  TNum      = return TNum
splitTypeByLabel' _  TBool     = return TBool
splitTypeByLabel' _  TNull     = return TNull
splitTypeByLabel' _ (TLabel r) = assert False $ return $ TLabel r -- unnecessary?
splitTypeByLabel' l (TUnion u) = do m <- mapM (splitTypeByLabel' l) $ Set.toList u
                                    return $! TUnion $! Set.fromList m
splitTypeByLabel' l (TArray a) = do m <- splitTypeByLabel' (l `Text.append` "Elt") a
                                    return $! TArray m
splitTypeByLabel' l (TObj   o) = do kvs <- forM (Map.toList $ unDict o) $ \(k, v) -> do
                                       component <- splitTypeByLabel' k v
                                       return (k, component)
                                    addType l (TObj $ Dict $ Map.fromList kvs)
                                    return $! TLabel l

-- | Splits initial type with a given label, into a mapping of object type names and object type structures.
splitTypeByLabel :: Text -> Type -> Map Text Type
splitTypeByLabel topLabel t = Map.map (foldl1' unifyTypes) finalState
  where
    finalize (TLabel l) = assert (l == topLabel) $ return ()
    finalize  topLevel  = addType topLabel topLevel
    initialState    = Map.empty
    (_, finalState) = runState (splitTypeByLabel' topLabel t >>= finalize) initialState

formatObjectType ::  Text -> Type -> DeclM Text
formatObjectType identifier (TObj o) = newDecl  identifier d
  where
    d = Map.toList $ unDict o
formatObjectType identifier  other   = newAlias identifier other

-- | Display an environment of types split by name.
displaySplitTypes ::  Map Text Type -> Text
displaySplitTypes dict = trace ("displaySplitTypes: " ++ show (toposort dict)) $ runDecl declarations
  where
    declarations =
      forM (toposort dict) $ \(name, typ) ->
        formatObjectType (normalizeTypeName name) typ

-- | Normalize type name by:
-- 1. Treating all characters that are not acceptable in Haskell variable name as end of word.
-- 2. Capitalizing each word, but a first (camelCase).
-- 3. Adding underscore if first character is non-alphabetic.
-- 4. Escaping Haskell keywords if the whole identifier is such keyword.
-- 5. If identifier is empty, then substituting "JsonEmptyKey" for its name.
normalizeTypeName :: Text -> Text
normalizeTypeName s  = ifEmpty "JsonEmptyKey"                  .
                       escapeKeywords                          .
                       escapeFirstNonAlpha                     .
                       Text.concat                             .
                       map capitalize                          .
                       filter     (not . Text.null)            .
                       Text.split (not . acceptableInVariable) $ s
  where
    ifEmpty x ""       = x
    ifEmpty _ nonEmpty = nonEmpty
    acceptableInVariable c = isAlpha c || isDigit c
    escapeFirstNonAlpha cs                  | Text.null cs =                   cs
    escapeFirstNonAlpha cs@(Text.head -> c) | isAlpha   c  =                   cs
    escapeFirstNonAlpha cs                                 = "_" `Text.append` cs

capitalize :: Text -> Text
capitalize word = Text.toUpper first `Text.append` rest
  where
    (first, rest) = Text.splitAt 1 word

uncapitalize :: Text -> Text
uncapitalize word = Text.toLower first `Text.append` rest
  where
    (first, rest) = Text.splitAt 1 word

-- | Topological sorting of splitted types so that it is accepted declaration order.
toposort :: Map Text Type -> [(Text, Type)]  
toposort splitted = map ((id &&& (splitted Map.!)) . fst3 . graphKey) $ Graph.topSort graph
  where
    (graph, graphKey) = Graph.graphFromEdges' $ map makeEntry $ Map.toList splitted
    makeEntry (k, v) = (k, k, allLabels v)

-- | Computes all type labels referenced by a given type.
allLabels :: Type -> [Text]
allLabels = flip go []
  where
    go (TLabel l) ls = l:ls
    go (TArray t) ls = go t ls
    go (TUnion u) ls = Set.foldr go ls          u
    go (TObj   o) ls = Map.foldr go ls $ unDict o
    go _other     ls = ls

-- * Finding candidates for extra unifications
-- | For a given splitted types, it returns candidates for extra
-- unifications.
unificationCandidates :: Map.HashMap t Type -> [[t]]
unificationCandidates = Map.elems             .
                        Map.filter candidates .
                        Map.fromListWith (++) .
                        concatMap entry       .
                        Map.toList
  where
    -- | Candidate entry has to have at least two candidates, so that unification makes sense
    candidates [ ] = False
    candidates [_] = False
    candidates _   = True
    -- | Make a candidate entry for each object type, which points from its keys to its label.
    entry (k, TObj o)                 = [(Set.fromList $ Map.keys $ unDict o, [k])]
    entry  _                          = [] -- ignore array elements and toplevel type if it is Array

-- | Unifies candidates on a give input list.
unifyCandidates :: [[Text]] -> Map Text Type -> Map Text Type
unifyCandidates candidates splitted = Map.map (remapLabels labelMapping) $ replacements splitted
  where
    unifiedType  :: [Text] -> Type
    unifiedType cset      = foldr1 unifyTypes         $ 
                            map (splitted Map.!) cset
    replace      :: [Text] -> Map Text Type -> Map Text Type
    replace  cset@(c:_) s = Map.insert c (unifiedType cset) (foldr Map.delete s cset)
    replace  []         _ = error "Empty candidate set in replace"
    replacements :: Map Text Type -> Map Text Type
    replacements        s = foldr replace s candidates
    labelMapping :: Map Text Text
    labelMapping          = Map.fromList $ concatMap mapEntry candidates
    mapEntry cset@(c:_)   = [(x, c) | x <- cset]
    mapEntry []           = error "Empty candidate set in mapEntry"

-- | Remaps type labels according to a `Map`.
remapLabels :: Map Text Text -> Type -> Type
remapLabels ls (TObj   o) = TObj   $ Dict $ Map.map (remapLabels ls) $ unDict o
remapLabels ls (TArray t) = TArray $                 remapLabels ls  t
remapLabels ls (TUnion u) = TUnion $        Set.map (remapLabels ls) u
remapLabels ls (TLabel l) = TLabel $ Map.lookupDefault l l ls
remapLabels _  other      = other

