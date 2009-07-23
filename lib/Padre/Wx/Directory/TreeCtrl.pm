package Padre::Wx::Directory::TreeCtrl;

use strict;
use warnings;
use File::Spec     ();
use File::Basename ();
use Params::Util   ('_INSTANCE');
use Padre::Current ();
use Padre::Util    ();
use Padre::Wx      ();

our $VERSION = '0.41';
our @ISA     = 'Wx::TreeCtrl';

use constant IS_MAC => !!( $^O eq 'darwin' );
use constant IS_WIN32 => !!( $^O =~ /^MSWin/ or $^O eq 'cygwin' );

################################################################################
# new                                                                          #
#                                                                              #
# Creates a new Directory Browser object                                       #
#                                                                              #
################################################################################
sub new {
	my $class = shift;
	my $panel = shift;
	my $self  = $class->SUPER::new(
		$panel,
		-1,
		Wx::wxDefaultPosition,
		Wx::wxDefaultSize,
		Wx::wxTR_HIDE_ROOT
		| Wx::wxTR_SINGLE
		| Wx::wxTR_FULL_ROW_HIGHLIGHT
		| Wx::wxTR_HAS_BUTTONS
		| Wx::wxTR_LINES_AT_ROOT
		| Wx::wxBORDER_NONE
	);

	# Files that must be skipped
	$self->{SKIP}   = sub { return ! 1 };
	$self->{CACHED} = {};

	# Selected item of each project
	$self->{current_item} = {};

	# Create the image list
	my $images = Wx::ImageList->new( 16, 16 );
	$self->{file_types} = {
		folder => $images->Add(
			Wx::ArtProvider::GetBitmap(
				'wxART_FOLDER', 'wxART_OTHER_C', [ 16, 16 ]
			),
		),
		package => $images->Add(
			Wx::ArtProvider::GetBitmap(
				'wxART_NORMAL_FILE', 'wxART_OTHER_C', [ 16, 16 ]
			),
		),
	};
	$self->AssignImageList($images);

	# Set up the events
	Wx::Event::EVT_TREE_ITEM_ACTIVATED(
		$self, $self,
		\&_on_tree_item_activated
	);

	Wx::Event::EVT_SET_FOCUS(
		$self,
		\&_on_focus
	);

	Wx::Event::EVT_TREE_ITEM_MENU(
		$self, $self,
		\&_on_tree_item_menu,
	);

	Wx::Event::EVT_TREE_SEL_CHANGED(
		$self, $self,
		\&_on_tree_sel_changed,
	);

	Wx::Event::EVT_TREE_ITEM_EXPANDING(
		$self, $self,
		\&_on_tree_item_expanding,
	);

	Wx::Event::EVT_TREE_ITEM_COLLAPSING(
		$self, $self,
		\&_on_tree_item_collapsing,
	);

	Wx::Event::EVT_TREE_END_LABEL_EDIT(
		$self, $self,
		\&_on_tree_end_label_edit,
	);

	Wx::Event::EVT_TREE_BEGIN_DRAG(
		$self, $self,
		\&_on_tree_begin_drag,
	);

	Wx::Event::EVT_TREE_END_DRAG(
		$self, $self,
		\&_on_tree_end_drag,
	);

	# Set up the root
	$self->AddRoot(
		Wx::gettext('Directory'),
		-1, -1,
		Wx::TreeItemData->new( {
			dir  => '',
			name => '',
			type => 'folder',
		} ),
	);

	# Ident to sub nodes
	$self->SetIndent(10);

	return $self;
}

################################################################################
# parent                                                                       #
#                                                                              #
# Returns the Directory Panel object reference                                 #
#                                                                              #
################################################################################
sub parent {
	$_[0]->GetParent;
}

################################################################################
# right                                                                        #
#                                                                              #
# Returns the right object reference (where the Directory Browser is placed)   #
#                                                                              #
################################################################################
sub right {
	$_[0]->GetGrandParent;
}

################################################################################
# main                                                                         #
#                                                                              #
# Returns the main object reference                                            #
#                                                                              #
################################################################################
sub main {
	$_[0]->GetGrandParent->GetParent;
}

################################################################################
# current                                                                      #
#                                                                              #
#                                                                              #
################################################################################
sub current {
	Padre::Current->new( main => $_[0]->main );
}

################################################################################
# clear                                                                        #
#                                                                              #
# Clears root node children                                                    #
#                                                                              #
################################################################################
sub clear {
	my $self = shift;
	$self->DeleteChildren( $self->GetRootItem );
	return;
}

################################################################################
# update_gui                                                                   #
#                                                                              #
# Updates the gui if needed                                                    #
#                                                                              #
################################################################################
sub update_gui {
	my $self     = shift;
	my $parent   = $self->parent;
	my $searcher = $self->parent->_searcher;

	######################################################################
	# Gets the last and current actived projects
	my $last_project = $parent->_last_project;
	my $current_project = $parent->_current_project;

	######################################################################
	# Updates Root node data
	$self->_update_root_data;

	######################################################################
	# Returns if Search is in use
	return if $searcher->{in_use}->{$current_project};

	######################################################################
	# Gets Root node
	my $root = $self->GetRootItem;

	# Lock the gui here to make the updates look slicker
	# The locker holds the gui freeze until the update is done.
	my $locker = $self->main->freezer;

	######################################################################
	# If the project have changed or the project root folder updates or
	# the search is not in use anymore (was just used)
	if ( (defined($current_project) and (not defined($last_project) or $last_project ne $current_project ) ) or $self->_updated_dir($current_project) or $searcher->{just_used}->{$current_project} ) {
		$self->_list_dir($root);
		delete $searcher->{just_used}->{$current_project};
	}

	######################################################################
	# Checks expanded sub folders and its content recursively
	_update_subdirs( $self, $root );
}

# Read a directory, removing the current and updir only.
# Returns the contents pre-split into directories and files so that
# we only have to do a -d file stat once and return by reference.
sub readdir {
	my $self      = shift;
	my $directory = shift;

	# Read the directory, and do the cheap name presort
	opendir( my $dh, $directory ) or return;
	my @buffer = sort { lc($a) cmp lc($b) } CORE::readdir( $dh );
	closedir( $dh );

	# Filter out ignored files and split out the directories
	# We don't use sort for the directory split, because it can
	# end up calling extra extra -d filesystem stats.
	my @files = ();
	my @dirs  = ();
	my $skip  = $self->{SKIP};
	foreach ( @buffer ) {
		if ( -d File::Spec->catfile( $directory, $_ ) ) {
			next if /^\.\.?\z/;
			push @dirs, $_;
		} else {
			push @files, $_;
		}
	}

	return ( \@dirs, \@files );
}

################################################################################
# _update_root_data                                                            #
#                                                                              #
# Updates root nodes data to the current project                               #
#                                                                              #
# Called when turned beteween projects                                         #
#                                                                              #
################################################################################
sub _update_root_data {
	my $self = shift;

	######################################################################
	# Splits the path to get the Root folder name and its path
	my ($volume, $path, $name) = File::Spec->splitpath(
		$self->parent->_current_project,
	);

	######################################################################
	# Updates Root node data
	my $root = $self->GetPlData( $self->GetRootItem );
	$root->{dir}  = $volume . $path;
	$root->{name} = $name;
}

################################################################################
# _list_dir                                                                    #
#                                                                              #
# Updates a node's content                                                     #
#                                                                              #
# Called only if project directory changes or show/hide hidden files is        #
# requested                                                                    #
#                                                                              #
################################################################################
sub _list_dir {
	my $self      = shift;
	my $node      = shift;
	my $node_data = $self->GetPlData($node);
	my $path      = File::Spec->catfile( $node_data->{dir}, $node_data->{name} );
	my $cached    = \%{ $self->{CACHED}->{$path} };

	######################################################################
	# Read folder's content and cache if it had changed or isn't cached
	if ( $self->_updated_dir($path) ) {

		######################################################################
		# Open the folder and sort its content by name and type
		my ($dirs, $files) = $self->readdir( $path );

		######################################################################
		# For each item, creates its CACHE data
		my @Data = map { {
			name => $_,
			dir  => $path,
			type => 'folder',
		} } @$dirs;
		push @Data, map { {
			name => $_,
			dir  => $path,
			type => 'package',
		} } @$files;
		$cached->{Data}   = \@Data;
		$cached->{Change} = ( stat $path )[10];
	}

	######################################################################
	# Show or hide hidden files
	my @data = @{ $cached->{Data} };
	unless ( $cached->{ShowHidden} ) {
		my $project = $self->current->project;
		if ( $project ) {
			my $rule = $project->ignore_rule;
			@data = grep { $rule->() } @data;
		}
		else {
			@data = grep { $_->{name} !~ /^\./ } @data;
		}
	}

	######################################################################
	# Delete node children and populates it again
	$self->DeleteChildren($node);
	foreach my $each ( @data ) {
		my $new_elem = $self->AppendItem(
			$node,
			$each->{name},
			-1, -1,
			Wx::TreeItemData->new( {
				name => $each->{name},
				dir  => $each->{dir},
				type => $each->{type},
			} )
		);
		if ( $each->{type} eq 'folder' ) {
			$self->SetItemHasChildren( $new_elem, 1 );
		}
		$self->SetItemImage(
			$new_elem,
			$self->{file_types}->{ $each->{type} },
			Wx::wxTreeItemIcon_Normal,
		);
	}
}

################################################################################
# _updated_dir                                                                 #
#                                                                              #
# Returns 1 if the directory has changed or is not cached and 0 if it's still  #
# the same                                                                     #
#                                                                              #
################################################################################
sub _updated_dir {
	my $self   = shift;
	my $dir    = shift;
	my $cached = $self->{CACHED}->{$dir};

	if ( not defined($cached) or !$cached->{Data} or !$cached->{Change} or ( stat $dir )[10] != $cached->{Change} or $self->parent->_searcher->{just_used}->{$dir} ) {
		return 1;
	}
	return 0;
}

################################################################################
# _update_subdirs                                                              #
#                                                                              #
# Runs thought a directory content recursively looking if each EXPANDED item   #
# has changed and updates it                                                   #
#                                                                              #
################################################################################
sub _update_subdirs {
	my ( $self, $root ) = @_;
	my $parent = $self->parent;
	my $project = $parent->_current_project;

	my $cookie;
	######################################################################
	# Loops thought the node's total children
	for my $item ( 1 .. $self->GetChildrenCount($root) ) {

		( my $node, $cookie ) = $item == 1 ? $self->GetFirstChild($root) : $self->GetNextChild( $root, $cookie );
		my $node_data = $self->GetPlData($node);
		my $path = File::Spec->catfile( $node_data->{dir}, $node_data->{name} );

		######################################################################
		# If the item (folder) was expanded, then expands its node and updates
		# its content recursively
		if ( defined $self->{CACHED}->{$project}->{Expanded}->{$path} ) {

			######################################################################
			# Expands the folder node
			$self->Expand($node);

			######################################################################
			# Updates the folder node if its content has any change
			$self->_list_dir($node) if $self->_updated_dir($path);

			######################################################################
			# Runs thought its content
			_update_subdirs( $self, $node );
		}

		######################################################################
		# If the item was the last selected item, selects and scrolls to it
		if ( defined $self->{current_item}->{$project} and $self->{current_item}->{$project} eq $path ) {
			$self->SelectItem($node);
			$self->ScrollTo($node);
		}
	}
}

################################################################################
# _removes_double_dot                                                          #
#                                                                              #
# Removes '..' and its previous directories                                    #
#                                                                              #
################################################################################
sub _removes_double_dot {
	my ( $self, $file ) = @_;
	my @dirs = File::Spec->splitdir($file);
	for ( my $i = 0; $i < @dirs; $i++ ) {
		splice @dirs, $i - 1, 2 if $i > 0 and $dirs[$i] eq "..";
	}
	return File::Spec->catfile(@dirs);
}

################################################################################
# _rename_or_move                                                              #
#                                                                              #
# Tries to rename a file and if success returns 1 or if fails shows a          #
# MessageBox with the reason and returns 0                                     #
#                                                                              #
################################################################################
sub _rename_or_move {
	my $self     = shift;
	my $old_file = $self->_removes_double_dot(shift);
	my $new_file = $self->_removes_double_dot(shift);

	######################################################################
	# Renames/moves the old file name to the new file name
	if ( rename $old_file, $new_file ) {

		######################################################################
		# Sets the new file to be selected
		my $project = $self->parent->_current_project;
		$self->{current_item}->{$project} = $new_file;

		######################################################################
		# Expands the node's parent (one level expand)
		my $cached = $self->{CACHED};
		$cached->{$project}->{Expanded}->{ File::Basename::dirname($new_file) } = 1;

		######################################################################
		# If the old file was expanded, keeps the new one expanded
		if ( defined $cached->{$project}->{Expanded}->{$old_file} ) {
			$cached->{$project}->{Expanded}->{$new_file} = 1;
			delete $cached->{$project}->{Expanded}->{$old_file};
		}

		######################################################################
		# Finds which is the OS separator character
		my $separator = File::Spec->catfile( $old_file, 'temp' );
		$separator =~ s/^$old_file(.?)temp$/$1/;

		######################################################################
		# Moves all cached data of the node and above it to the new path
		map {
			$cached->{ $new_file . ( defined $1 ? $1 : '' ) } = $cached->{$_}, delete $cached->{$_}
				if $_ =~ /^$old_file($separator.+?)?$/
		} keys %$cached;
		
		######################################################################
		# Returns success
		return 1;
	} else {
		######################################################################
		# Popups the error message and returns fail
		my $error_msg = $!;
		Wx::MessageBox( $error_msg, Wx::gettext('Error'), Wx::wxOK | Wx::wxCENTRE | Wx::wxICON_ERROR );
		return 0;
	}
}

################################################################################
#                                                                              #
#                                                                              #
#                                                                              #
#                          DIRECTORY BROWSER EVENTS                            #
#                                                                              #
#                Executed when an pre estabilished event occurs                #
#                                                                              #
#                                                                              #
#                                                                              #
################################################################################

################################################################################
# _on_focus                                                                    #
#                                                                              #
# Action that must be executaded when the Directory Browser receives focus     #
#                                                                              #
################################################################################
sub _on_focus {
	my ( $self, $event ) = @_;
	my $main = $self->main;
	$self->update_gui if $main->has_directory;
}

################################################################################
# _on_tree_item_activated                                                      #
#                                                                              #
# Action that must be executaded when a item is activated                      #
#                                                                              #
# Called when the item is actived                                              #
#                                                                              #
################################################################################
sub _on_tree_item_activated {
	my ( $self, $event ) = @_;
	my $node      = $event->GetItem;
	my $node_data = $self->GetPlData($node);

	######################################################################
	# If its a folder, expands/collapses it and returns
	if ( $node_data->{type} eq "folder" ) {
		$self->Toggle($node);
		return;
	}

	######################################################################
	# Returns if the selected FILE have no path
	my $path = File::Spec->catfile( $node_data->{dir}, $node_data->{name} );
	return if not defined $path;

	######################################################################
	# Opens the selected file
	my $main = $self->main;
	if ( my $id = $main->find_editor_of_file($path) ) {
		my $page = $main->notebook->GetPage($id);
		$page->SetFocus;
	} else {
		$main->setup_editors($path);
	}
	return;
}

################################################################################
# _on_tree_end_label_edit                                                      #
#                                                                              #
# Verifies if the new file name already exists and prompt if it does or rename #
# the file if don't                                                            #
#                                                                              #
# Called when a item label is edited                                           #
#                                                                              #
################################################################################
sub _on_tree_end_label_edit {
	my ( $self, $event ) = @_;

	######################################################################
	# Returns if no label is typed
	return unless $event->GetLabel();

	######################################################################
	# Node old and new names and paths
	my $node_data = $self->GetPlData( $event->GetItem );
	my $old_file  = File::Spec->catfile( $node_data->{dir}, $node_data->{name} );
	my $new_file  = File::Spec->catfile( $node_data->{dir}, $event->GetLabel() );
	my $new_label = ( File::Spec->splitpath($new_file) )[2];

	#########################################################################
	# Loops while already exists a file with the new label name
	while ( -e $new_file ) {

		######################################################################
		# Prompts the user asking for a new name for the file
		my $prompt = Wx::TextEntryDialog->new(
			$self,
			Wx::gettext('Please, choose a different name.'),
			Wx::gettext('File already exists'),
			$new_label,
		);

		######################################################################
		# If Cancel button pressed, ignores changes and returns
		if ( $prompt->ShowModal == Wx::wxID_CANCEL ) {
			$event->Veto();
			return;
		}

		######################################################################
		# Reads the new file name and generates its complete path
		$new_file = File::Spec->catfile( $node_data->{dir}, $prompt->GetValue );
		$new_label = ( File::Spec->splitpath($new_file) )[2];
		$prompt->Destroy;
	}

	######################################################################
	# Ignores changes if the renaming have no success
	$event->Veto() unless $self->_rename_or_move( $old_file, $new_file );
	return;
}

################################################################################
# _on_tree_sel_changed                                                         #
#                                                                              #
# Caches the item path as current selected item                                #
#                                                                              #
# Called when a item is selected                                               #
#                                                                              #
################################################################################
sub _on_tree_sel_changed {
	my ( $self, $event ) = @_;
	my $node_data = $self->GetPlData( $event->GetItem );

	######################################################################
	# Caches the item path
	$self->{current_item}->{ $self->parent->_current_project } = File::Spec->catfile( $node_data->{dir}, $node_data->{name} );
}

################################################################################
# _on_tree_item_expanding                                                      #
#                                                                              #
# Expands the node and loads its content                                       #
#                                                                              #
# Called when a folder is expanded                                             #
#                                                                              #
################################################################################
sub _on_tree_item_expanding {
	my ( $self, $event ) = @_;
	my $node      = $event->GetItem;
	my $node_data = $self->GetPlData($node);

	######################################################################
	# Returns if a search is being done (expands only the browser listing)
	return if $self->parent->_searcher->{in_use}->{$self->parent->_current_project};

	######################################################################
	# The item complete path
	my $path = File::Spec->catfile( $node_data->{dir}, $node_data->{name} );

	######################################################################
	# Cache the expanded state of the node
	$self->{CACHED}->{ $self->parent->_current_project }->{Expanded}->{$path} = 1;

	######################################################################
	# Updates the node content if it changed or has no child
	if ( $self->_updated_dir($path) or !$self->GetChildrenCount($node) ) {
		$self->_list_dir($node);
	}
}

################################################################################
# _on_tree_item_collapsing                                                     #
#                                                                              #
# Deletes nodes Expanded cache param                                           #
#                                                                              #
# Called when a folder is collapsed                                            #
#                                                                              #
################################################################################
sub _on_tree_item_collapsing {
	my ( $self, $event ) = @_;
	my $node_data = $self->GetPlData( $event->GetItem );

	######################################################################
	# Deletes cache expanded state of the node
	delete $self->{CACHED}->{ $self->parent->_current_project }->{Expanded}->{ File::Spec->catfile( $node_data->{dir}, $node_data->{name} ) };
}

################################################################################
# _on_tree_begin_drag                                                          #
#                                                                              #
# If the item is not the root node let it to be dragged                        #
#                                                                              #
# Called when a item is dragged                                                #
#                                                                              #
################################################################################
sub _on_tree_begin_drag {
	my ( $self, $event ) = @_;
	my $node = $event->GetItem;

	######################################################################
	# Only drags if it's not the Root node
	if ( $node != $self->GetRootItem ) {
		$self->{dragged_item} = $node;
		$event->Allow;
	}
}

################################################################################
# _on_tree_end_drag                                                            #
#                                                                              #
# If dragged to a different folder, tries to move (renaming) it to the new     #
# folder.                                                                      #
#                                                                              #
# Called just after the item is dragged                                        #
#                                                                              #
################################################################################
sub _on_tree_end_drag {
	my ( $self, $event ) = @_;
	my $node = $event->GetItem;

	######################################################################
	# If drops to a file, the new destination will be it's folder
	if ( $node->IsOk and !$self->ItemHasChildren($node) ) {
		$node = $self->GetItemParent($node);
	}

	######################################################################
	# Returns if the target node doesn't exists
	return if !$node->IsOk;

	######################################################################
	# Gets dragged and target nodes data
	my $new_data = $self->GetPlData($node);
	my $old_data = $self->GetPlData( $self->{dragged_item} );


	######################################################################
	# Returns if the target is the file parent
	my $from = $old_data->{dir};
	my $to = File::Spec->catfile( $new_data->{dir}, $new_data->{name} );
	return if $from eq $to;

	######################################################################
	# The file complete name (path and its name) before and after the move
	my $old_file = File::Spec->catfile( $old_data->{dir}, $old_data->{name} );
	my $new_file = File::Spec->catfile( $to, $old_data->{name} );

	######################################################################
	# Alerts if there is a file with the same name in the target
	if ( -e $new_file ) {
		Wx::MessageBox(
			Wx::gettext('Already exists a file with the same name in this directory'),
			Wx::gettext('Error'),
			Wx::wxOK | Wx::wxCENTRE | Wx::wxICON_ERROR
		);
		return;
	}

	######################################################################
	# If the move (renaming) sucess, updates the Browser gui
	$self->update_gui if $self->_rename_or_move( $old_file, $new_file );
	return;
}

################################################################################
# _on_tree_item_menu                                                           #
#                                                                              #
# Shows up a context menu above an item with its controls                      #
# the file if don't                                                            #
#                                                                              #
# Called when a item context menu is requested                                 #
#                                                                              #
################################################################################
sub _on_tree_item_menu {
	my ( $self, $event ) = @_;
	my $node      = $event->GetItem;
	my $node_data = $self->GetPlData($node);

	my $menu          = Wx::Menu->new;
	my $selected_dir  = $node_data->{dir};
	my $selected_path = File::Spec->catfile( $node_data->{dir}, $node_data->{name} );

	######################################################################
	# Default action - same when the item is activated
	my $default =
		$menu->Append( -1, Wx::gettext( $node_data->{type} eq 'folder' ? 'Expand / Collapse' : 'Open File' ) );
	Wx::Event::EVT_MENU(
		$self, $default,
		sub { $self->_on_tree_item_activated($event) }
	);
	$menu->AppendSeparator();

	######################################################################
	# Rename and/or move the item
	my $rename = $menu->Append( -1, Wx::gettext('Rename / Move') );
	Wx::Event::EVT_MENU(
		$self, $rename,
		sub {
			$self->EditLabel($node);
		},
	);

	######################################################################
	# Move item to trash
	# Note: File::Remove->trash() only works in Win and Mac

	if ( IS_WIN32 or IS_MAC ) {
		my $trash = $menu->Append( -1, Wx::gettext('Move to trash') );
		Wx::Event::EVT_MENU(
			$self, $trash,
			sub {
				eval {
					require File::Remove;
					File::Remove->trash($selected_path);
				};
				if ($@) {
					my $error_msg = $@;
					Wx::MessageBox(
						$error_msg, Wx::gettext('Error'),
						Wx::wxOK | Wx::wxCENTRE | Wx::wxICON_ERROR
					);
				}
				return;
			},
		);
	}

	######################################################################
	# Delete item
	my $delete = $menu->Append( -1, Wx::gettext('Delete') );
	Wx::Event::EVT_MENU(
		$self, $delete,
		sub {

			my $dialog = Wx::MessageDialog->new(
				$self,
				Wx::gettext('You sure want to delete this item?') . $/ . $selected_path,
				Wx::gettext('Delete'),
				Wx::wxYES_NO | Wx::wxICON_QUESTION | Wx::wxCENTRE
			);
			return if $dialog->ShowModal == Wx::wxID_NO;

			eval {
				require File::Remove;
				File::Remove->remove($selected_path);
			};
			if ($@) {
				my $error_msg = $@;
				Wx::MessageBox(
					$error_msg, Wx::gettext('Error'),
					Wx::wxOK | Wx::wxCENTRE | Wx::wxICON_ERROR
				);
			}
			return;
		},
	);

	######################################################################
	# ?????
	if ( defined $node_data->{type} and ( $node_data->{type} eq 'modules' or $node_data->{type} eq 'pragmata' ) ) {
		my $pod = $menu->Append( -1, Wx::gettext("Open &Documentation") );
		Wx::Event::EVT_MENU(
			$self, $pod,
			sub {

				# TODO Fix this wasting of objects (cf. Padre::Wx::Menu::Help)
				require Padre::Wx::DocBrowser;
				my $help = Padre::Wx::DocBrowser->new;
				$help->help( $node_data->{name} );
				$help->SetFocus;
				$help->Show(1);
				return;
			},
		);
	}
	$menu->AppendSeparator();

	######################################################################
	# Shows / Hides hidden files - applied to each directory
	my $hiddenFiles     = $menu->AppendCheckItem( -1, Wx::gettext('Show hidden files') );
	my $applies_to_node = $node;
	my $applies_to_path = $selected_path;
	if ( $node_data->{type} ne 'folder' ) {
		$applies_to_path = $selected_dir;
		$applies_to_node = $self->GetParent($node);
	}

	my $cached = \%{ $self->{CACHED}->{$applies_to_path} };
	my $show   = $cached->{ShowHidden};
	$hiddenFiles->Check($show);
	Wx::Event::EVT_MENU(
		$self,
		$hiddenFiles,
		sub {
			$cached->{ShowHidden} = !$show;
			$self->_list_dir($applies_to_node);
		},
	);

	######################################################################
	# Updates the directory listing
	my $reload = $menu->Append( -1, Wx::gettext('Reload') );
	Wx::Event::EVT_MENU(
		$self, $reload,
		sub {
			delete $self->{CACHED}->{ $self->GetPlData($node)->{dir} }->{Change};
		}
	);

	######################################################################
	# Pops up the context menu
	my $x = $event->GetPoint->x;
	my $y = $event->GetPoint->y;
	$self->PopupMenu( $menu, $x, $y );

	return;
}

1;

# Copyright 2008-2009 The Padre development team as listed in Padre.pm.
# LICENSE
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl 5 itself.
