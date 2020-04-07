{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
module NixManager.Packages.View
  ( packagesBox
  )
where

import NixManager.NixLocation(flattenedTail)
import           NixManager.Packages.PackageCategory
                                                ( packageCategories
                                                , categoryToText
                                                , PackageCategory
                                                  ( PackageCategoryAll
                                                  )
                                                )
import           NixManager.View.ComboBox       ( comboBox
                                                , ComboBoxProperties
                                                  ( ComboBoxProperties
                                                  )
                                                , ComboBoxChangeEvent
                                                  ( ComboBoxChangeEvent
                                                  )
                                                )
import           NixManager.View.ProgressBar    ( progressBar )
import qualified NixManager.View.IconName      as IconName
import           NixManager.Packages.Event      ( Event
                                                  ( EventSearchChanged
                                                  , EventCategoryChanged
                                                  , EventPackageSelected
                                                  , EventTryInstall
                                                  , EventInstall
                                                  , EventUninstall
                                                  , EventTryInstallCancel
                                                  )
                                                , InstallationType
                                                  ( Cancelled
                                                  , Uncancelled
                                                  )
                                                )
import           NixManager.ManagerEvent        ( ManagerEvent
                                                  ( ManagerEventPackages
                                                  )
                                                )
import           NixManager.NixPackageStatus    ( _NixPackageInstalled
                                                , _NixPackagePendingInstall
                                                , _NixPackagePendingUninstall
                                                , NixPackageStatus
                                                  ( NixPackageNothing
                                                  , NixPackageInstalled
                                                  , NixPackagePendingInstall
                                                  , NixPackagePendingUninstall
                                                  )
                                                )
import           NixManager.NixPackage          ( NixPackage
                                                , npStatus
                                                , npName
                                                , npPath
                                                , npDescription
                                                )
import           Data.Maybe                     ( isJust
                                                , fromMaybe
                                                )
import           Prelude                 hiding ( length
                                                , null
                                                , unlines
                                                , init
                                                )
import           Data.Text                      ( length
                                                , Text
                                                , init
                                                , unlines
                                                , null
                                                , stripPrefix
                                                )
import           GI.Gtk.Declarative.Container.Class
                                                ( Children )
import           Data.Default                   ( def )
import           GI.Gtk.Declarative             ( bin
                                                , Widget
                                                , padding
                                                , Container
                                                , FromWidget
                                                , Bin
                                                , widget
                                                , Attribute((:=))
                                                , classes
                                                , container
                                                , BoxChild(BoxChild)
                                                , on
                                                , onM
                                                )
import qualified Data.Vector                   as Vector
import qualified GI.Gtk                        as Gtk
import           Data.GI.Base.Overloading       ( IsDescendantOf )
import           Control.Lens                   ( (^.)
                                                , (^..)
                                                , to
                                                , has
                                                , folded
                                                )
import           NixManager.ManagerState        ( ManagerState
                                                , msPackagesState
                                                )
import           NixManager.Packages.State      ( psSearchString
                                                , psCategoryIdx
                                                , isCounter
                                                , psSearchResult
                                                , psSelectedPackage
                                                , psLatestMessage
                                                , psInstallingPackage
                                                , State
                                                , psCategory
                                                )
import           NixManager.Util                ( replaceHtmlEntities
                                                , surroundSimple
                                                )
import           NixManager.View.GtkUtil        ( paddedAround
                                                , expandAndFill
                                                )
import           NixManager.View.ImageButton    ( imageButton )
import           NixManager.Message             ( messageText
                                                , messageType
                                                , _ErrorMessage
                                                )
import           Control.Monad.IO.Class         ( MonadIO )


processSearchChange
  :: (IsDescendantOf Gtk.Entry o, MonadIO f, Gtk.GObject o)
  => o
  -> f ManagerEvent
processSearchChange w =
  ManagerEventPackages . EventSearchChanged <$> Gtk.getEntryText w

searchLabel :: Widget event
searchLabel =
  widget Gtk.Label [#label := "Search in packages:", #halign := Gtk.AlignEnd]

searchField :: Widget ManagerEvent
searchField = widget
  Gtk.SearchEntry
  [ #placeholderText := "Enter a package name or part of a name..."
  , #maxWidthChars := 50
  , onM #searchChanged processSearchChange
  , #halign := Gtk.AlignFill
  ]

searchBox :: State -> Widget ManagerEvent
searchBox s =
  let changeCallback (ComboBoxChangeEvent idx) =
          ManagerEventPackages (EventCategoryChanged (fromIntegral idx))
  in  container
        Gtk.Box
        [#orientation := Gtk.OrientationHorizontal, #spacing := 10]
        [ BoxChild expandAndFill searchLabel
        , BoxChild expandAndFill searchField
        , BoxChild def $ changeCallback <$> comboBox
          []
          (ComboBoxProperties (categoryToText <$> packageCategories)
                              (s ^. psCategoryIdx)
          )
        ]

formatPkgLabel :: NixPackage -> Text
formatPkgLabel pkg =
  let
    path = pkg ^. npPath . flattenedTail
    name = pkg ^. npName
    firstLine = ["<span size=\"x-large\">" <> name <> "</span>"]
    descriptionLine
      | null (pkg ^. npDescription)
      = []
      | otherwise
      = ["Description: " <> pkg ^. npDescription . to (surroundSimple "i" . replaceHtmlEntities)]
    pathLine = ["Full Nix path: " <> surroundSimple "tt" path | path /= name]
    formatStatus NixPackageNothing          = []
    formatStatus NixPackageInstalled        = ["Installed"]
    formatStatus NixPackagePendingInstall   = ["Marked for installation"]
    formatStatus NixPackagePendingUninstall = ["Marked for uninstallation"]
  in
    init
    . unlines
    $ (  firstLine
      <> pathLine
      <> descriptionLine
      <> (surroundSimple "b" <$> formatStatus (pkg ^. npStatus))
      )


buildResultRow
  :: FromWidget (Bin Gtk.ListBoxRow) target => Int -> NixPackage -> target event
buildResultRow i pkg = bin
  Gtk.ListBoxRow
  [classes [if i `mod` 2 == 0 then "package-row-even" else "package-row-odd"]]
  (widget
    Gtk.Label
    [ #useMarkup := True
    , #label := formatPkgLabel pkg
    , #halign := Gtk.AlignStart
    ]
  )

rowSelectionHandler :: Maybe Gtk.ListBoxRow -> Gtk.ListBox -> IO ManagerEvent
rowSelectionHandler (Just row) _ = do
  selectedIndex <- Gtk.listBoxRowGetIndex row
  if selectedIndex == -1
    then pure (ManagerEventPackages (EventPackageSelected Nothing))
    else pure
      (ManagerEventPackages
        (EventPackageSelected (Just (fromIntegral selectedIndex)))
      )
rowSelectionHandler _ _ =
  pure (ManagerEventPackages (EventPackageSelected Nothing))

packagesBox
  :: FromWidget (Container Gtk.Box (Children BoxChild)) target
  => ManagerState
  -> target ManagerEvent
packagesBox s =
  let
    searchValid =
      ((s ^. msPackagesState . psCategory) /= PackageCategoryAll)
        || (s ^. msPackagesState . psSearchString . to length)
        >= 2
    resultRows = Vector.fromList
      (zipWith buildResultRow
               [0 ..]
               (s ^.. msPackagesState . psSearchResult . folded)
      )
    packageSelected = isJust (s ^. msPackagesState . psSelectedPackage)
    currentPackageStatus =
      msPackagesState . psSelectedPackage . folded . npStatus
    currentPackageInstalled =
      has (currentPackageStatus . _NixPackageInstalled) s
    currentPackagePendingInstall =
      has (currentPackageStatus . _NixPackagePendingInstall) s
    currentPackagePendingUninstall =
      has (currentPackageStatus . _NixPackagePendingUninstall) s
    tryInstallCell = case s ^. msPackagesState . psInstallingPackage of
      Nothing -> BoxChild
        expandAndFill
        (imageButton
          [ #label := "Try without installing"
          , #sensitive
            := (  packageSelected
               && not currentPackageInstalled
               && not currentPackagePendingUninstall
               )
          , classes ["try-install-button"]
          , on #clicked (ManagerEventPackages EventTryInstall)
          , #alwaysShowImage := True
          ]
          IconName.SystemRun
        )
      Just is -> BoxChild expandAndFill $ container
        Gtk.Box
        [#orientation := Gtk.OrientationHorizontal, #spacing := 5]
        [ BoxChild def $ imageButton
          [ #alwaysShowImage := True
          , on #clicked (ManagerEventPackages EventTryInstallCancel)
          , #label := "Cancel"
          ]
          IconName.ProcessStop
        , BoxChild expandAndFill $ progressBar
          [#showText := True, #text := "Downloading..."]
          (is ^. isCounter)
        ]
    packageButtonRow = container
      Gtk.Box
      [#orientation := Gtk.OrientationHorizontal, #spacing := 10]
      [ tryInstallCell
      , BoxChild
        expandAndFill
        (imageButton
          [ #label
            := (if currentPackagePendingUninstall
                 then "Cancel uninstall"
                 else "Mark for installation"
               )
          , #sensitive
            := (  packageSelected
               && not currentPackageInstalled
               && not currentPackagePendingInstall
               )
          , classes ["install-button"]
          , on
            #clicked
            (ManagerEventPackages
              (if currentPackagePendingUninstall
                then EventInstall Cancelled
                else EventInstall Uncancelled
              )
            )
          , #alwaysShowImage := True
          ]
          IconName.SystemSoftwareInstall
        )
      , BoxChild
        expandAndFill
        (imageButton
          [ #label
            := (if currentPackageInstalled
                 then "Mark for removal"
                 else "Cancel installation"
               )
          , #sensitive
            := (  packageSelected
               && (currentPackageInstalled || currentPackagePendingInstall)
               )
          , classes ["remove-button"]
          , #alwaysShowImage := True
          , on
            #clicked
            (ManagerEventPackages
              (if currentPackageInstalled
                then EventUninstall Uncancelled
                else EventUninstall Cancelled
              )
            )
          ]
          IconName.EditDelete
        )
      ]
    resultBox = if searchValid
      then bin
        Gtk.ScrolledWindow
        []
        (container
          Gtk.ListBox
          [onM #rowSelected rowSelectionHandler, classes ["packages-list"]]
          resultRows
        )
      else widget
        Gtk.Label
        [ #label := "Please enter a search term with at least two characters"
        , #expand := True
        ]
  in
    paddedAround 10 $ container
      Gtk.Box
      [#orientation := Gtk.OrientationVertical, #spacing := 10]
      (  [ BoxChild (def { padding = 5 }) (searchBox (s ^. msPackagesState))
         , widget Gtk.HSeparator []
         ]
      <> foldMap
           (\e ->
             [ BoxChild
                 def
                 (widget
                   Gtk.Label
                   [ #label := (e ^. messageText)
                   , #useMarkup := True
                   , classes
                     [ if has (messageType . _ErrorMessage) e
                         then "error-message"
                         else "info-message"
                     ]
                   ]
                 )
             ]
           )
           (s ^. msPackagesState . psLatestMessage)

      <> [ packageButtonRow
         , widget Gtk.HSeparator []
         , BoxChild expandAndFill resultBox
         ]
      )

