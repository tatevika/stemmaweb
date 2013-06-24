package stemmaweb::Controller::Relation;
use JSON qw/ to_json from_json /;
use Moose;
use Module::Load;
use namespace::autoclean;
use TryCatch;

BEGIN { extends 'Catalyst::Controller' }


=head1 NAME

stemmaweb::Controller::Relation - Controller for the relationship mapper

=head1 DESCRIPTION

The reading relationship mapper with draggable nodes.

=head1 METHODS

=head2 index

 GET relation/$textid
 
Renders the application for the text identified by $textid.

=cut

sub index :Path :Args(0) {
	my( $self, $c ) = @_;
	$c->stash->{'template'} = 'relate.tt';
}

=head2 text

 GET relation/$textid/
 
 Runs the relationship mapper for the specified text ID.
 
=cut

sub text :Chained('/') :PathPart('relation') :CaptureArgs(1) {
	my( $self, $c, $textid ) = @_;
	my $tradition = $c->model('Directory')->tradition( $textid );
	unless( $tradition ) {
		$c->response->status('404');
		$c->response->body("No such tradition with ID $textid");
		$c->detach('View::Plain');
		return;
	}
	
    # Account for a bad interaction between FastCGI and KiokuDB
    unless( $tradition->collation->tradition ) {
        $c->log->warn( "Fixing broken tradition link" );
        $tradition->collation->_set_tradition( $tradition );
        $c->model('Directory')->save( $tradition );
    }
    # Check permissions. Will return 403 if denied, otherwise will
    # put the appropriate value in the stash.
    my $ok = _check_permission( $c, $tradition );
    return unless $ok;

	$c->stash->{'textid'} = $textid;
	$c->stash->{'tradition'} = $tradition;
}

sub main :Chained('text') :PathPart('') :Args(0) {
	my( $self, $c ) = @_;
	my $tradition = delete $c->stash->{'tradition'};
	my $collation = $tradition->collation;
	
	# Stash the relationship definitions
	$c->stash->{'relationship_scopes'} = to_json( [ qw/ local global / ] );
	my @reltypeinfo;
	foreach my $type ( sort { _typesort( $a, $b ) } $collation->relations->types ) {
		next if $type->is_weak;
		my $struct = { name => $type->name, description => $type->description };
		push( @reltypeinfo, $struct );
	}
	$c->stash->{'relationship_types'} = to_json( \@reltypeinfo );
	
	# See how big the tradition is. Edges are more important than nodes
	# when it comes to rendering difficulty.
	my $numnodes = scalar $collation->readings;
	my $numedges = scalar $collation->paths;
	my $length = $collation->end->rank;
	# We should display no more than roughly 500 nodes, or roughly 700
	# edges, at a time.
	my $segments = $numnodes / 500;
	if( $numedges / 700 > $segments ) {
		$segments = $numedges / 700;
	}
	my $segsize = sprintf( "%.0f", $length / $segments );
	my $margin = sprintf( "%.0f", $segsize / 10 );
	if( $segments > 1 ) {
		# Segment the tradition in order not to overload the browser.
		my @divs;
		my $r = 0;
		while( $r + $margin < $length ) {
			push( @divs, $r );
			$r += $segsize;
		}
		$c->stash->{'textsegments'} = [];
		foreach my $i ( 0..$#divs ) {
			my $seg = { 'start' => $divs[$i] };
			$seg->{'display'} = "Segment " . ($i+1);
			push( @{$c->stash->{'textsegments'}}, $seg );
		}
	}
	my $startseg = $c->req->param('start');
	my $svgopts;
	if( $startseg ) {
		# Only render the subgraph from startseg to endseg or to END,
		# whichever is less.
		my $endseg = $startseg + $segsize + $margin;
		$svgopts = { 'from' => $startseg };
		$svgopts->{'to'} = $endseg if $endseg < $collation->end->rank;
	} elsif( exists $c->stash->{'textsegments'} ) {
		# This is the unqualified load of a long tradition. We implicitly start 
		# at zero, but go only as far as our segment size.
		my $endseg = $segsize + $margin;
		$startseg = 0;
		$svgopts = { 'to' => $endseg };
	}
	# Spit out the SVG
	my $svg_str = $collation->as_svg( $svgopts );
	$svg_str =~ s/\n//gs;
	$c->stash->{'startseg'} = $startseg if defined $startseg;
	$c->stash->{'svg_string'} = $svg_str;
	$c->stash->{'text_title'} = $tradition->name;
	if( $tradition->can('language') ) {
		$c->stash->{'text_lang'} = $tradition->language;
		$c->stash->{'can_morphologize'} = 1;
	} else {
		$c->stash->{'text_lang'} = 'Default';
	}
	$c->stash->{'template'} = 'relate.tt';
}

sub _typesort {
	my( $a, $b ) = @_;
	my $blsort = $a->bindlevel <=> $b->bindlevel;
	return $blsort if $blsort;
	return $a->name cmp $b->name;
}

=head2 help

 GET relation/help/$language

Returns the help window HTML.

=cut

sub help :Local :Args(1) {
	my( $self, $c, $lang ) = @_;
	# Display the morphological help for the language if it is defined.
	if( $lang && $lang ne 'Default' ) {
		my $mod = 'Text::Tradition::Language::' . $lang;
		try {
			load( $mod );
		} catch {
			$c->log->debug("Warning: could not load $mod");
		}
		my $has_mod = $mod->can('morphology_tags');
		if( $has_mod ) {
			my $tagset = &$has_mod;
			$c->stash->{'tagset'} = $tagset;
		}
	}
	$c->stash->{'template'} = 'relatehelp.tt';
}

=head2 relationships

 GET relation/$textid/relationships

Returns the list of relationships defined for this text.

 POST relation/$textid/relationships { request }
 
Attempts to define the requested relationship within the text. Returns 200 on
success or 403 on error.

 DELETE relation/$textid/relationships { request }
 

=cut

sub relationships :Chained('text') :PathPart :Args(0) {
	my( $self, $c ) = @_;
	my $tradition = delete $c->stash->{'tradition'};
	my $ok = _check_permission( $c, $tradition );
	return unless $ok;
	my $collation = $tradition->collation;
	my $m = $c->model('Directory');
	if( $c->request->method eq 'GET' ) {
		my @pairs = $collation->relationships; # returns the edges
		my @all_relations;
		foreach my $p ( @pairs ) {
			my $relobj = $collation->relations->get_relationship( @$p );
			next if $relobj->type eq 'collated'; # Don't show these
			next if $p->[0] eq $p->[1]; # HACK until bugfix
			my $relhash = { source => $p->[0], target => $p->[1], 
				  type => $relobj->type, scope => $relobj->scope };
			$relhash->{'note'} = $relobj->annotation if $relobj->has_annotation;
			push( @all_relations, $relhash );
		}
		$c->stash->{'result'} = \@all_relations;
	} else {
		# Check write permissions first of all
		if( $c->stash->{'permission'} ne 'full' ) {
			$c->response->status( '403' );
			$c->stash->{'result'} = { 
				'error' => 'You do not have permission to modify this tradition.' };
			$c->detach( 'View::JSON' );
		} elsif( $c->request->method eq 'POST' ) {
			my $node = $c->request->param('source_id');
			my $target = $c->request->param('target_id');
			my $relation = $c->request->param('rel_type');
			my $note = $c->request->param('note');
			my $scope = $c->request->param('scope');
		
			my $opts = { 'type' => $relation, 'propagate' => 1 };
			$opts->{'scope'} = $scope if $scope;
			$opts->{'annotation'} = $note if $note;
			
			try {
				my @vectors = $collation->add_relationship( $node, $target, $opts );
				$c->stash->{'result'} = \@vectors;
				$m->save( $tradition );
			} catch( Text::Tradition::Error $e ) {
				$c->response->status( '403' );
				$c->stash->{'result'} = { 'error' => $e->message };
			}
		} elsif( $c->request->method eq 'DELETE' ) {
			my $node = $c->request->param('source_id');
			my $target = $c->request->param('target_id');
			my $scopewide = $c->request->param('scopewide') 
				&& $c->request->param('scopewide') eq 'true';
			try {
				my @vectors = $collation->del_relationship( $node, $target, $scopewide );
				$m->save( $tradition );
				$c->stash->{'result'} = \@vectors;
			} catch( Text::Tradition::Error $e ) {
				$c->response->status( '403' );
				$c->stash->{'result'} = { 'error' => $e->message };
			}	
		}
	}
	$c->forward('View::JSON');
}

=head2 readings

 GET relation/$textid/readings

Returns the list of readings defined for this text along with their metadata.

=cut

my %read_write_keys = (
	'id' => 0,
	'text' => 0,
	'is_meta' => 0,
	'grammar_invalid' => 1,
	'is_nonsense' => 1,
	'normal_form' => 1,
);

sub _reading_struct {
	my( $reading ) = @_;
	# Return a JSONable struct of the useful keys.  Keys meant to be writable
	# have a true value; read-only keys have a false value.
	my $struct = {};
	map { $struct->{$_} = $reading->$_ if $reading->can( $_ ) } keys( %read_write_keys );
	# Special case
	$struct->{'lexemes'} = $reading->can( 'lexemes' ) ? [ $reading->lexemes ] : [];
	# Look up any words related via spelling or orthography
	my $sameword = sub { 
		my $t = $_[0]->type;
		return $t eq 'spelling' || $t eq 'orthographic';
	};
	# Now add the list data
	$struct->{'variants'} = [ map { $_->text } $reading->related_readings( $sameword ) ];
	$struct->{'witnesses'} = [ $reading->witnesses ];
	return $struct;
}

sub readings :Chained('text') :PathPart :Args(0) {
	my( $self, $c ) = @_;
	my $tradition = delete $c->stash->{'tradition'};
	my $ok = _check_permission( $c, $tradition );
	return unless $ok;
	my $collation = $tradition->collation;
	my $m = $c->model('Directory');
	if( $c->request->method eq 'GET' ) {
		my $rdginfo = {};
		foreach my $rdg ( $collation->readings ) {
			$rdginfo->{$rdg->id} = _reading_struct( $rdg );
		}
		$c->stash->{'result'} = $rdginfo;
	}
	$c->forward('View::JSON');
}

=head2 reading

 GET relation/$textid/reading/$id

Returns the list of readings defined for this text along with their metadata.

 POST relation/$textid/reading/$id { request }
 
Alters the reading according to the values in request. Returns 403 Forbidden if
the alteration isn't allowed.

=cut

sub reading :Chained('text') :PathPart :Args(1) {
	my( $self, $c, $reading_id ) = @_;
	my $tradition = delete $c->stash->{'tradition'};
	my $collation = $tradition->collation;
	my $rdg = $collation->reading( $reading_id );
	my $m = $c->model('Directory');
	if( $c->request->method eq 'GET' ) {
		$c->stash->{'result'} = $rdg ? _reading_struct( $rdg )
			: { 'error' => "No reading with ID $reading_id" };
	} elsif ( $c->request->method eq 'POST' ) {
		if( $c->stash->{'permission'} ne 'full' ) {
			$c->response->status( '403' );
			$c->stash->{'result'} = { 
				'error' => 'You do not have permission to modify this tradition.' };
			$c->detach('View::JSON');
			return;
		}
		my $errmsg;
		if( $rdg && $rdg->does('Text::Tradition::Morphology') ) {
			# Are we re-lemmatizing?
			if( $c->request->param('relemmatize') ) {
				my $nf = $c->request->param('normal_form');
				# TODO throw error unless $nf
				$rdg->normal_form( $nf );
				# TODO throw error if lemmatization fails
				# TODO skip this if normal form hasn't changed
				$rdg->lemmatize();
			} else {
				# Set all the values that we have for the reading.
				# TODO error handling
				foreach my $p ( keys %{$c->request->params} ) {
					if( $p =~ /^morphology_(\d+)$/ ) {
						# Set the form on the correct lexeme
						my $morphval = $c->request->param( $p );
						next unless $morphval;
						my $midx = $1;
						my $lx = $rdg->lexeme( $midx );
						my $strrep = $rdg->language . ' // ' . $morphval;
						my $idx = $lx->has_form( $strrep );
						unless( defined $idx ) {
							# Make the word form and add it to the lexeme.
							try {
								$idx = $lx->add_matching_form( $strrep ) - 1;
							} catch( Text::Tradition::Error $e ) {
								$c->response->status( '403' );
								$errmsg = $e->message;
							} catch {
								# Something else went wrong, probably a Moose error
								$c->response->status( '403' );
								$errmsg = 'Something went wrong with the request';	
							}
						}
						$lx->disambiguate( $idx ) if defined $idx;
					} elsif( $read_write_keys{$p} ) {
						my $val = _clean_booleans( $rdg, $p, $c->request->param( $p ) );
						$rdg->$p( $val );
					}
				}		
			}
			$m->save( $rdg );
		} else {
			$errmsg = "Reading does not exist or cannot be morphologized";
		}
		$c->stash->{'result'} = $errmsg ? { 'error' => $errmsg }
			: _reading_struct( $rdg );

	}
	$c->forward('View::JSON');

}

=head2 duplicate

 POST relation/$textid/duplicate { data }
 
Duplicates the requested readings, detaching the witnesses specified in
the list to use the new reading(s) instead of the old. The data to be
passed should be a JSON structure:

 { readings: rid1,rid2,rid3,...
   witnesses: [ wit1, ... ] }

=cut

sub duplicate :Chained('text') :PathPart :Args(0) {
	my( $self, $c ) = @_;
	my $tradition = delete $c->stash->{'tradition'};
	my $collation = $tradition->collation;
	my $m = $c->model('Directory');
	if( $c->request->method eq 'POST' ) {
		if( $c->stash->{'permission'} ne 'full' ) {
			$c->response->status( '403' );
			$c->stash->{'result'} = { 
				'error' => 'You do not have permission to modify this tradition.' };
			$c->detach('View::JSON');
			return;
		}
		my $errmsg;
		my $response = {};
		# Sort out which readings need to be duplicated from the set given, and
		# ensure that all the given wits bear each relevant reading.
		
		my %wits = ();
		map { $wits{$_} = 1 } $c->request->param('witnesses[]');
		my %rdgranks = ();
		foreach my $rid ( $c->request->param('readings[]') ) {
			my $numwits = 0;
			my $rdg = $collation->reading( $rid );
			foreach my $rwit ( $rdg->witnesses( $rid ) ) {
				$numwits++ if exists $wits{$rwit};
			}
			if( $numwits > 0 && $numwits < keys( %wits ) ) {
				$errmsg = "Reading $rid contains some but not all of the specified witnesses.";
				last;
			} elsif( exists $rdgranks{ $rdg->rank } ) {
				$errmsg = "More than one reading would be detached along with $rid at rank " . $rdg->rank;
				last;
			} else {
				$rdgranks{ $rdg->rank } = $rid;
			}
		}
		
		# Now check that the readings make a single sequence.
		unless( $errmsg ) {
			my $prior;
			foreach my $rank ( sort { $a <=> $b } keys %rdgranks ) {
				my $rid = $rdgranks{$rank};
				if( $prior ) {
					# Check that there is only one path between $prior and $rdg.
					foreach my $wit ( keys %wits ) {
						unless( $collation->prior_reading( $rid, $wit ) eq $prior ) {
							$errmsg = "Diverging witness paths from $prior to $rid at $wit";
							last;
						}
					}
				}
				$prior = $rid;
			}
		}
		
		# Abort if we've run into a problem.
		if( $errmsg ) {
			$c->stash->{'result'} = { 'error' => $errmsg };
			$c->response->status( '403' );
			$c->forward('View::JSON');
			return;
		}
		
		# Otherwise, do the dirty work.
		my @witlist = keys %wits;
		foreach my $rank ( sort { $a <=> $b } keys %rdgranks ) {
			my $newrdg;
			my $reading_id = $rdgranks{$rank};
			try {
				$newrdg = $collation->duplicate_reading( $reading_id, @witlist );
			} catch( Text::Tradition::Error $e ) {
				$c->response->status( '403' );
				$errmsg = $e->message;
			} catch {
				# Something else went wrong, probably a Moose error
				$c->response->status( '403' );
				$errmsg = 'Something went wrong with the request';	
			}
			if( $newrdg ) {
				$response->{$reading_id} = _reading_struct( $newrdg );
			}
		} 
		if( $errmsg ) {
			$c->stash->{'result'} = { 'error' => $errmsg };
		} else {
			$m->save( $collation );
			$c->stash->{'result'} = $response;
		}
	}
	$c->forward('View::JSON');
}



sub _check_permission {
	my( $c, $tradition ) = @_;
    my $user = $c->user_exists ? $c->user->get_object : undef;
    # Does this user have access?
    if( $user ) {
   		if( $user->is_admin || 
    			( $tradition->has_user && $tradition->user->id eq $user->id ) ) {
			$c->stash->{'permission'} = 'full';
			return 1;
		}
    } 
    # Is it public?
    if( $tradition->public ) {
    	$c->stash->{'permission'} = 'readonly';
    	return 1;
    } 
	# Forbidden!
	$c->response->status( 403 );
	$c->response->body( 'You do not have permission to view this tradition.' );
	$c->detach( 'View::Plain' );
	return 0;
}

sub _clean_booleans {
	my( $rdg, $param, $val ) = @_;
	if( $rdg->meta->get_attribute( $param )->type_constraint->name eq 'Bool' ) {
		$val = 1 if $val eq 'true';
		$val = undef if $val eq 'false';
	} 
	return $val;
}

=head2 end

Attempt to render a view, if needed.

=cut

sub end : ActionClass('RenderView') {}

=head1 AUTHOR

Tara L Andrews

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
