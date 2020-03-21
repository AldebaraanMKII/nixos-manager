{-# LANGUAGE OverloadedStrings #-}
module NixManager.NixServiceOptionType
  ( NixServiceOptionType(..)
  , parseNixServiceOptionType
  )
where

import           Data.List                      ( intercalate )
import           Data.Bifunctor                 ( first )
import           Control.Monad                  ( void )
import           Data.Functor                   ( ($>) )
import           Data.Void                      ( Void )
import           Data.Text                      ( Text
                                                , pack
                                                , unpack
                                                )
import qualified Text.Megaparsec.Char.Lexer    as L
import           Text.Megaparsec.Char           ( char
                                                , string
                                                )
import           Text.Megaparsec                ( Parsec
                                                , manyTill
                                                , sepBy
                                                , optional
                                                , errorBundlePretty
                                                , parse
                                                , (<|>)
                                                , (<?>)
                                                )
import           NixManager.Util

data NixServiceOptionType = NixServiceOptionInteger
                         | NixServiceOptionAttributeSet
                         | NixServiceOptionBoolean
                         | NixServiceOptionOr NixServiceOptionType NixServiceOptionType
                         | NixServiceOptionOneOfNumeric [Integer]
                         | NixServiceOptionOneOfString [Text]
                         | NixServiceOptionString
                         | NixServiceOptionList NixServiceOptionType
                         | NixServiceOptionPackage
                         | NixServiceOptionPath
                         | NixServiceOptionSubmodule
                         | NixServiceOptionUnspecified
                         | NixServiceOptionNull
  deriving(Eq)

instance Show NixServiceOptionType where
  show NixServiceOptionInteger      = "integer"
  show NixServiceOptionString       = "string"
  show (NixServiceOptionList t)     = "list of " <> show t <> "s"
  show NixServiceOptionBoolean      = "boolean"
  show NixServiceOptionPackage      = "package"
  show NixServiceOptionAttributeSet = "attribute set"
  show NixServiceOptionPath         = "path"
  show NixServiceOptionSubmodule    = "submodule"
  show NixServiceOptionUnspecified  = "unspecified"
  show NixServiceOptionNull         = "null"
  show (NixServiceOptionOneOfNumeric xs) =
    "one of " <> intercalate ", " (show <$> xs)
  show (NixServiceOptionOneOfString xs) =
    "one of " <> intercalate ", " (unpack <$> xs)
  show (NixServiceOptionOr a b) = show a <> " or " <> show b

type Parser = Parsec Void Text

decimalParser :: Parser Integer
decimalParser = L.decimal

stringLiteral :: Parser String
stringLiteral =
  (char '\"' *> manyTill L.charLiteral (char '\"')) <?> "string literal"

serviceOptionTypeParser :: Parser NixServiceOptionType
serviceOptionTypeParser =
  let
    booleanParser :: Parser NixServiceOptionType
    booleanParser = string "boolean" $> NixServiceOptionBoolean <?> "boolean"
    stringParser :: Parser NixServiceOptionType
    stringParser = string "string" $> NixServiceOptionString <?> "string"
    nullParser :: Parser NixServiceOptionType
    nullParser = string "null" $> NixServiceOptionNull <?> "null"
    packageParser :: Parser NixServiceOptionType
    packageParser = string "package" $> NixServiceOptionPackage <?> "package"
    pathParser :: Parser NixServiceOptionType
    pathParser = string "path" $> NixServiceOptionPath <?> "path"
    submoduleParser :: Parser NixServiceOptionType
    submoduleParser =
      string "submodule" $> NixServiceOptionSubmodule <?> "submodule"
    unspecifiedParser :: Parser NixServiceOptionType
    unspecifiedParser =
      string "unspecified" $> NixServiceOptionUnspecified <?> "unspecified"
    listParser :: Parser NixServiceOptionType
    listParser = do
      void (string "list of ")
      expr <- expressionParser
      void (string "s")
      pure (NixServiceOptionList expr)
    attributeSetUntyped =
      string "attribute set" $> NixServiceOptionAttributeSet
    attributeSetTyped = do
      void (string "attribute set of ")
      void expressionParser
      void (string "s")
      pure NixServiceOptionAttributeSet
    attributeSetParser :: Parser NixServiceOptionType
    attributeSetParser = attributeSetTyped <|> attributeSetUntyped
    oneOfParser :: Parser NixServiceOptionType
    oneOfParser = do
      void (string "one of ")
      stringSuffix  <- optional (stringLiteral `sepBy` string ", ")
      numericSuffix <- optional (decimalParser `sepBy` string ", ")
      case stringSuffix of
        Nothing -> case numericSuffix of
          Just numbers -> pure (NixServiceOptionOneOfNumeric numbers)
          Nothing ->
            fail "\"one of\" with neither strings nor integers, not supported"
        Just strings -> pure (NixServiceOptionOneOfString (pack <$> strings))
    integerParser =
      optional (decimalParser *> string " bit ")
        *> optional (string "unsigned " <|> string "signed ")
        *> string "integer"
        *> optional
             (  optional (string ";")
             *> string " between "
             *> decimalParser
             *> string " and "
             *> decimalParser
             *> string " (both inclusive)"
             )
        $> NixServiceOptionInteger
    atomicsParser =
      nullParser
        <|> booleanParser
        <|> stringParser
        <|> packageParser
        <|> pathParser
        <|> submoduleParser
        <|> unspecifiedParser
        <|> (integerParser <?> "integer")
        <|> (oneOfParser <?> "\"one of\" expression")
        <|> (listParser <?> "\"list of\" expression")
        <|> (attributeSetParser <?> "\"attribute set\" expression")
    expressionParser = do
      prefix <- atomicsParser
      suffix <- optional (string " or " *> expressionParser)
      case suffix of
        Nothing      -> pure prefix
        Just suffix' -> pure (NixServiceOptionOr prefix suffix')
  in
    expressionParser

parseNixServiceOptionType :: Text -> MaybeError NixServiceOptionType
parseNixServiceOptionType t = fromEither
  ( first errorBundlePretty
  . parse serviceOptionTypeParser "NixOS type expression"
  $ t
  )

