package stemmaweb::Neo4J::Reading;
use strict;
use warnings;
use Moose;

has baseurl => (
	is => 'ro',
	isa => 'Str'
);

has id => (
	is => 'ro',
	isa => 'Str'
);

has text => (
	is => 'ro',
	isa => 'Str',
	writer => '_set_text',
);

has is_meta => (
	is => 'ro',
	isa => 'Bool',
	writer => '_set_is_meta',
);

has is_start => (
	is => 'ro',
	isa => 'Bool',
	writer => '_set_is_start',
);

has is_end => (
	is => 'ro',
	isa => 'Bool',
	writer => '_set_is_end',
);

has grammar_invalid => (
	is => 'ro',
	isa => 'Bool',
	writer => '_set_grammar_invalid',
);

has is_nonsense => (
	is => 'ro',
	isa => 'Bool',
	writer => '_set_is_nonsense',
);

has normal_form => (
	is => 'ro',
	isa => 'Str',
	writer => '_set_normal_form',
);

has witnesses => (
	is => 'ro',
	isa => 'Str',
	writer => '_set_witnesses',
);

has lexemes => (
	is => 'ro',
	isa => 'Str',
	writer => '_set_lexemes',
);



sub BUILDARGS {
	my( $self, $tradition_repo, $id ) = @_;
	# We get passed a tradition URL and a vector. Construct the URL.
	# Reading URLS don't have the tradition/ID/ prepended to them.
	$tradition_repo =~ s!/tradition.*$!!;
	return {
		baseurl => sprintf("%s/reading/%s", $tradition_repo, $id),
		sigil => $id
	};	
}

sub merge {
	
}

sub duplicate {
	
}

sub split {
	
}

sub related_readings {
	
}

__PACKAGE__->meta->make_immutable;

1;