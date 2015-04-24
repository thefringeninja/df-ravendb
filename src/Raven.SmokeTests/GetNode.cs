using System;
using System.Linq;
using Raven.Abstractions.Indexing;
using Raven.Client.Indexes;

namespace Raven.SmokeTests
{
    public static class GetNode
    {
        public class Query
        {
            public Query()
            {
            }

            public Query(string id)
            {
                Id = id;
            }

            public string Id { get; set; }

            public override string ToString()
            {
                return string.Format("Get Node with id : '{0}'", Id);
            }
        }

        public class Response
        {
            public Response()
            {
                References = new ReferencedNode[0];
                ReferencedBy = new ReferencedNode[0];
                Attributes = new NodeAttribute[0];

                Locations = new ReferencedNode[0];
            }
            public string Id { get; set; }
            public string Type { get; set; }
            public string Name { get; set; }
            public string Code { get; set; }

            public string Source { get; set; }

            public NodeAttribute[] Attributes { get; set; }

            public ReferencedNode Site { get; set; }
            public ReferencedNode[] Locations { get; set; }
            public ReferencedNode[] Systems { get; set; }
            public ReferencedNode[] References { get; set; }
            public ReferencedNode[] ReferencedBy { get; set; }
        }

        public class NodeAttribute
        {
            public NodeAttribute()
            {
            }

            public NodeAttribute(string key, string value)
            {
                Key = key;
                Value = value;
            }

            public string Key { get; set; }
            public string Value { get; set; }

            public override string ToString()
            {
                return string.Format("Attribute: ({0},{1})", Key, Value);
            }
        }

        public class ReferencedNode
        {
            public ReferencedNode(String id, string type, string code, string name)
            {
                Code = code;
                Id = id;
                Name = name;
                Type = type;
            }

            public ReferencedNode()
            {

            }

            public string Id { get; set; }
            public string Code { get; set; }
            public string Type { get; set; }
            public string Name { get; set; }

            public override string ToString()
            {
                return string.Format("ReferencedNode:Id: {0}, Code: {1}, Type: {2}, Name: {3}", Id, Code, Type, Name);
            }
        }

        internal class ReferencedByIndex : AbstractIndexCreationTask<NodeProjection, ReferencedByIndex.Result>
        {
            public class Result
            {
                public string Id { get; set; }
                public ReferencedNode[] ReferencedBy { get; set; }
            }

            public ReferencedByIndex()
            {
                Map = nodes =>
                    from node in nodes
                    let references = LoadDocument<NodeProjection>(node.References)
                    from reference in references
                    select new Result
                    {
                        Id = reference.Id,
                        ReferencedBy = new[]
                        {
                            new ReferencedNode
                            {
                                Id = node.Id,
                                Type = node.Type,
                                Code = node.Code,
                                Name = node.Name
                            }
                        }
                    };
                Reduce = nodes =>
                    from node in nodes
                    group node by node.Id
                    into g
                    select new Result
                    {
                        Id = g.Key,
                        ReferencedBy = g.SelectMany(x => x.ReferencedBy).ToArray()
                    };
                StoreAllFields(FieldStorage.Yes);
            }
        }

        internal class Transformer : AbstractTransformerCreationTask<NodeProjection>
        {
            public override string TransformerName
            {
                get { return "GetNode"; }
            }

            public Transformer()
            {
                TransformResults = nodes =>
                    from node in nodes
                    let references = LoadDocument<NodeProjection>(node.References)
                    let allParents = Recurse(node, x => LoadDocument<NodeProjection>(x.References)).Where(x => x.Id != node.Id)
                    let site = allParents.FirstOrDefault(x => string.Equals(x.Type, Const.Types.Site, StringComparison.CurrentCultureIgnoreCase))
                    let locations = allParents.Where(x => string.Equals(x.Type, Const.Types.Location, StringComparison.CurrentCultureIgnoreCase))
                    let systems = allParents.Where(x => string.Equals(x.Type, Const.Types.System, StringComparison.CurrentCultureIgnoreCase))
                    select new Response
                    {
                        Id = node.Id,
                        Source = node.Source,
                        Type = node.Type,
                        Code = node.Code,
                        Site = (site != null)
                            ? new ReferencedNode
                            {
                                Id = site.Id,
                                Code = site.Code,
                                Name = site.Name,
                                Type = site.Type
                            }
                            : null,
                        Attributes = node.Attributes.Select(x => new NodeAttribute
                        {
                            Key = x.Key,
                            Value = x.Value,

                        }).OrderBy(x => x.Key).ToArray(),
                        Name = node.Name,
                        References = references.Select(x => new ReferencedNode()
                        {
                            Id = x.Id,
                            Code = x.Code,
                            Name = x.Name,
                            Type = x.Type
                        }).OrderBy(x => x.Code).ToArray(),
                        Systems = systems.Select(x => new ReferencedNode()
                        {
                            Id = x.Id,
                            Code = x.Code,
                            Name = x.Name,
                            Type = x.Type
                        }).ToArray(),
                        Locations = locations.Select(x => new ReferencedNode
                        {
                            Id = x.Id,
                            Code = x.Code,
                            Name = x.Name,
                            Type = x.Type
                        }).OrderBy(x => x.Code).ToArray()
                    };
            }
        }

        internal class DoNotTransformNodeProjection : AbstractTransformerCreationTask<NodeProjection>
        {
            public override string TransformerName
            {
                get { return "DoNotTransformNodeProjection"; }
            }

            public DoNotTransformNodeProjection()
            {
                TransformResults = nodes =>
                    from node in nodes
                    select node;
            }
        }

        public class NodeProjection
        {
            public NodeProjection()
            {
                Attributes = new AttributeProjection[0];
                References = new string[] { };
            }
            public string Id { get; set; }

            public string Type { get; set; }
            public string Name { get; set; }
            public string ExternalKey { get; set; }
            public string Code { get; set; }
            public string Source { get; set; }
            public AttributeProjection[] Attributes { get; set; }

            public string[] References { get; set; }

            public bool Missing { get; set; }

            public string GetAttributeValue(string key, bool throwIfNotFound = false)
            {
                var attribute = Attributes.FirstOrDefault(x => x.Key == key);
                if (attribute == null)
                {
                    if (throwIfNotFound)
                        throw new InvalidOperationException(string.Format("Cannot find attribute with key {0} on node with id {1}.", key, Id));

                    return null;
                }

                return attribute.Value;
            }

            public override string ToString()
            {
                return string.Format("Id: {0}, Name: {1}, ExternalKey: {2}, Type: {3}, Code: {4}, Source: {5}, References ({6})", Id, Name, ExternalKey, Type, Code, Source, string.Join(",", References));
            }
        }
   }
}