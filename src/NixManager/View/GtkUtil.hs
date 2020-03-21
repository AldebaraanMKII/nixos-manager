{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
module NixManager.View.GtkUtil where

import           GI.Gtk.Declarative             ( bin
                                                , padding
                                                , defaultBoxChildProperties
                                                , on
                                                , expand
                                                , container
                                                , fill
                                                , widget
                                                , Attribute((:=))
                                                , classes
                                                , container
                                                , BoxChild(BoxChild)
                                                , on
                                                )
import qualified GI.Gtk                        as Gtk


paddedAround spacing =
  container Gtk.Box [#orientation := Gtk.OrientationVertical]
    . pure
    . BoxChild defaultBoxChildProperties { padding = spacing
                                         , expand  = True
                                         , fill    = True
                                         }
    . container Gtk.Box []
    . pure
    . BoxChild defaultBoxChildProperties { padding = spacing
                                         , expand  = True
                                         , fill    = True
                                         }
