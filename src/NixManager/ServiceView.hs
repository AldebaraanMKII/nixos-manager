{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
module NixManager.ServiceView
  ( servicesBox
  )
where

import           NixManager.NixExpr             ( NixExpr
                                                , _NixFunctionDecl'
                                                , nfExpr
                                                , _NixSet'
                                                , _NixBoolean'
                                                )
import           NixManager.ComboBox            ( comboBox
                                                , ComboBoxProperties
                                                  ( ComboBoxProperties
                                                  )
                                                )
import qualified Data.Vector                   as Vector
import           Data.Text                      ( intercalate
                                                , Text
                                                )
import           NixManager.Util                ( showText
                                                , replaceTag
                                                , removeTag
                                                )
import           NixManager.NixServiceOption    ( optionType
                                                , NixServiceOption
                                                , optionLoc
                                                , optionDescription
                                                )
import           GI.Gtk.Declarative.Widget      ( Widget )
import           GI.Gtk.Declarative.SingleWidget
                                                ( SingleWidget )
import           GI.Gtk.Declarative             ( bin
                                                , onM
                                                , pane
                                                , paned
                                                , classes
                                                , fill
                                                , expand
                                                , defaultPaneProperties
                                                , BoxChild(BoxChild)
                                                , defaultBoxChildProperties
                                                , FromWidget
                                                , Bin
                                                , widget
                                                , Attribute((:=))
                                                , container
                                                )
import           Data.Vector.Lens               ( toVectorOf )
import qualified GI.Gtk                        as Gtk
import           Control.Lens                   ( (^.)
                                                , pre
                                                , traversed
                                                , ix
                                                , non
                                                , (^?)
                                                , to
                                                , folded
                                                , (^..)
                                                , (^?!)
                                                )
import           NixManager.ManagerState        ( msServiceCache
                                                , ManagerState
                                                , msServiceExpression
                                                , msSelectedServiceIdx
                                                )
import           NixManager.ManagerEvent        ( ManagerEvent
                                                  ( ManagerEventDiscard
                                                  , ManagerEventServiceSelected
                                                  )
                                                )
import           NixManager.NixService          ( NixService
                                                , serviceLoc
                                                , serviceOptions
                                                )
import           NixManager.NixServiceOptionType
                                                ( NixServiceOptionType
                                                  ( NixServiceOptionString
                                                  , NixServiceOptionPath
                                                  , NixServiceOptionSubmodule
                                                  , NixServiceOptionBoolean
                                                  , NixServiceOptionUnspecified
                                                  , NixServiceOptionOneOf
                                                  , NixServiceOptionPackage
                                                  , NixServiceOptionInteger
                                                  , NixServiceOptionOr
                                                  )
                                                )


buildServiceRow
  :: FromWidget (Bin Gtk.ListBoxRow) target => NixService -> target event
buildServiceRow svc = bin
  Gtk.ListBoxRow
  []
  (widget Gtk.Label
          [#label := (svc ^. serviceLoc . to tail . to (intercalate "."))]
  )

rowSelectionHandler :: Maybe Gtk.ListBoxRow -> Gtk.ListBox -> IO ManagerEvent
rowSelectionHandler (Just row) _ = do
  selectedIndex <- Gtk.listBoxRowGetIndex row
  if selectedIndex == -1
    then pure (ManagerEventServiceSelected Nothing)
    else pure (ManagerEventServiceSelected (Just (fromIntegral selectedIndex)))
rowSelectionHandler _ _ = pure (ManagerEventServiceSelected Nothing)

serviceRows :: ManagerState -> Vector.Vector (Bin Gtk.ListBoxRow event)
serviceRows = toVectorOf (msServiceCache . folded . to buildServiceRow)

servicesLeftPane
  :: FromWidget (Bin Gtk.ScrolledWindow) target
  => ManagerState
  -> target ManagerEvent
servicesLeftPane s = bin
  Gtk.ScrolledWindow
  []
  (container Gtk.ListBox [onM #rowSelected rowSelectionHandler] (serviceRows s))

isStringy :: NixServiceOptionType -> Bool
isStringy NixServiceOptionString    = True
isStringy NixServiceOptionPath      = True
isStringy NixServiceOptionSubmodule = True
isStringy NixServiceOptionPackage   = True
isStringy NixServiceOptionInteger   = True
isStringy (NixServiceOptionOr l r)  = isStringy l && isStringy r
isStringy _                         = False

buildOptionValueCell
  :: Maybe NixExpr
  -> NixServiceOption
  -> GI.Gtk.Declarative.Widget.Widget ManagerEvent
buildOptionValueCell optionValue serviceOption =
  case serviceOption ^. optionType of
    Left e -> widget
      Gtk.Label
      [#label := ("Option value \"" <> e <> "\" not implemented yet")]
    Right NixServiceOptionBoolean -> widget
      Gtk.Switch
      [#active := (optionValue ^. pre (traversed . _NixBoolean') . non False)]
    Right NixServiceOptionUnspecified -> widget
      Gtk.Label
      [ classes ["unspecified-label"]
      , #label := "Type not specified, cannot edit."
      ]
    Right (NixServiceOptionOneOf values) ->
      ManagerEventDiscard <$ comboBox [] (ComboBoxProperties values Nothing)
    Right v -> if isStringy v
      then widget Gtk.Entry []
      else widget
        Gtk.Label
        [ #label
            := ("Option value \"" <> showText v <> "\" not implemented yet")
        ]

convertMarkup :: Text -> Text
convertMarkup =
  replaceTag "filename" "tt"
    . replaceTag "literal" "tt"
    . replaceTag "command" "tt"
    . replaceTag "option"  "tt"
    . replaceTag "varname" "tt"
    . removeTag "refentrytitle"
    . removeTag "manvolnum"
    . removeTag "link"
    . replaceTag "citerefentry" "tt"

buildOptionRows :: NixExpr -> NixServiceOption -> BoxChild ManagerEvent
buildOptionRows serviceExpression serviceOption =
  let
    optionPath :: Text
    optionPath = serviceOption ^. optionLoc . to (intercalate ".")
    optionValue :: Maybe NixExpr
    optionValue =
      (  serviceExpression
      ^? _NixFunctionDecl'
      .  nfExpr
      .  _NixSet'
      .  ix optionPath
      )
    optionBox = container
      Gtk.Box
      [#orientation := Gtk.OrientationHorizontal, #spacing := 10, #margin := 15]
      [ BoxChild (defaultBoxChildProperties { expand = True, fill = True })
        $ widget
            Gtk.Label
            [ classes ["service-option-title"]
            , #label
              := (serviceOption ^. optionLoc . to (intercalate "." . drop 2))
            , #halign := Gtk.AlignStart
            ]
      , BoxChild defaultBoxChildProperties
        $ buildOptionValueCell optionValue serviceOption
      ]
    rootBox = container
      Gtk.Box
      [#orientation := Gtk.OrientationVertical, #spacing := 5]
      [ optionBox
      , widget
        Gtk.Label
        [ classes ["service-option-description"]
        , #label := (serviceOption ^. optionDescription . to convertMarkup)
        , #wrap := True
        , #useMarkup := True
        ]
      ]
  in
    BoxChild defaultBoxChildProperties rootBox

servicesRightPane
  :: ( FromWidget (SingleWidget Gtk.Label) target
     , FromWidget (Bin Gtk.ScrolledWindow) target
     )
  => NixManager.ManagerState.ManagerState
  -> target ManagerEvent

servicesRightPane s = case s ^. msSelectedServiceIdx of
  Nothing ->
    widget Gtk.Label [#label := "Please select a service from the left pane"]
  Just idx ->
    let
      svc      = s ^?! msServiceCache . ix idx
      svcLabel = svc ^. serviceLoc . to (intercalate "." . tail)
      optBox =
        container Gtk.Box
                  [#orientation := Gtk.OrientationVertical, #spacing := 10]
          $ Vector.fromList
              ( BoxChild
                  defaultBoxChildProperties
                  (widget Gtk.Label
                          [classes ["service-headline"], #label := svcLabel]
                  )
              : (svc ^.. serviceOptions . folded . to
                  (buildOptionRows (s ^. msServiceExpression))
                )
              )
    in
      bin Gtk.ScrolledWindow [] optBox

servicesBox :: ManagerState -> Widget ManagerEvent
servicesBox s = paned []
                      (pane defaultPaneProperties (servicesLeftPane s))
                      (pane defaultPaneProperties (servicesRightPane s))
